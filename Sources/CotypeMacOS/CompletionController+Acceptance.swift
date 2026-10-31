import Foundation
import AppKit
import Combine
import CotypeCore

extension CompletionController {
    /// Dismiss the remainder of a commit chain, but only if it is still the
    /// active candidate. A stale chain's failure must never clear a newer
    /// generation's ghost.
    func dismissCommitRemainder(epoch: Int) {
        guard epoch == activeRenderGenerationID else { return }
        _ = applyInteraction(.dismissed)
    }

    /// Accept the whole suggestion (full-suggestion chord / menu). Routes through
    /// the machine so the loop stays consistent.
    public func accept() {
        guard canAcceptVisiblePreview(), candidateAvailable, activeAppIdentifier != "unknown" else {
            return
        }
        guard isFocusTargetValid() else {
            CotypeLog.loop.info("drop: focus target changed before accept in \(self.activeAppIdentifier, privacy: .public)")
            cancel(recordingRejection: true)
            return
        }
        applyInteraction(.acceptAll)
    }

    /// The visible-preview acceptance invariant: a candidate may only be
    /// inserted while its ghost is on screen and, in a browser, while the same
    /// website is still the one the candidate was generated for. Both accept
    /// entry points use this, and the commit path re-checks it immediately
    /// before inserting.
    func canAcceptVisiblePreview() -> Bool {
        guard phase == .awaitingAccept else { return false }
        let previewVisible = isGhostVisible
            || (!rendererReportsVisibility && lastRenderedGhost?.isEmpty == false)
        guard previewVisible else {
            CotypeLog.loop.info("drop: accept while no preview is visible in \(self.activeAppIdentifier, privacy: .public)")
            return false
        }
        guard isWebsiteIdentityUnchanged() else {
            CotypeLog.loop.info("drop: website changed before accept in \(self.activeAppIdentifier, privacy: .public)")
            cancel(recordingRejection: true)
            return false
        }
        return true
    }

    /// In a browser, the captured host must still be the shown host. Unknown or
    /// changed identity fails closed: the site rule that allowed the candidate
    /// may no longer apply after a navigation.
    func isWebsiteIdentityUnchanged() -> Bool {
        guard AppCompatibility.isBrowser(activeAppIdentifier) else { return true }
        let current = browserDomainProvider.currentDomain(appIdentifier: activeAppIdentifier)
        return current == activeWebsiteDomain
    }

    /// Accept a segment of the candidate into the editor. For a full accept the
    /// loop ends (state idle); for a stepped next-word accept the remaining ghost
    /// stays and the tracked prefix advances.
    ///
    /// Commits are **serialized** (each awaits the previous one) and scoped to a
    /// commit-chain *epoch* (the generation that produced the candidate). If any
    /// commit in the chain fails, only that epoch is latched and its remainder is
    /// dismissed; a later generation has a distinct epoch and is never poisoned.
    /// Each segment revalidates the exact focus target just before insert (fail
    /// closed on a moved caret), and a successful stepped insert refreshes the
    /// captured target so the next queued segment validates against the new caret.
    func commitSegment(_ text: String) {
        guard !text.isEmpty else { return }
        // The invariant is checked at the public accept entry points, then again
        // here before anything is queued: no visible preview, no insertion.
        guard canAcceptVisiblePreview() else { return }
        // Already-failed chain: refuse (a fresh epoch is needed to accept again).
        if failedCommitEpochs.contains(activeRenderGenerationID) { return }
        let epoch = activeRenderGenerationID
        let appIdentifier = activeAppIdentifier
        let prefix = activePrefix
        flow.accept()
        pipelineTask?.cancel()

        let keepAccepting = interaction.state == .awaitingAccept
        let chainEnding = !keepAccepting
        if keepAccepting {
            activePrefix = prefix + text
        }
        // Deliberately do NOT clearActiveState here: the in-flight commit chain
        // still needs `activeFocusTarget` (and the request identity) to revalidate
        // each queued segment. The last chain task clears it after the final insert
        // (a worked example of the orchestrator's "full accept may capture its
        // target before clear state").

        let previous = commitTask
        commitTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Skip if this chain was superseded by a fresh generation or already
            // failed — never insert a segment the machine no longer stands behind.
            guard self.activeRenderGenerationID == epoch,
                  !self.failedCommitEpochs.contains(epoch) else { return }

            // Revalidate the CURRENT exact target against the expected one (the
            // target the previous insert left, or the captured one for the first
            // segment). The field-aware inserter re-verifies the passed target
            // too, so a moved caret fails closed here or at insert.
            guard self.isFocusTargetValid() else {
                CotypeLog.loop.info("drop: focus target changed before insert in \(appIdentifier, privacy: .public)")
                await MainActor.run {
                    self.failedCommitEpochs.insert(epoch)
                    self.dismissCommitRemainder(epoch: epoch)
                    if chainEnding { self.clearRequestIdentity() }
                    self.personalization.recordFailed(appIdentifier: appIdentifier)
                    self.lastError = "The focus changed before the completion was inserted."
                }
                return
            }
            // A browser that navigated after the preview was drawn invalidates
            // the website rule the candidate was generated under.
            guard self.isWebsiteIdentityUnchanged() else {
                CotypeLog.loop.info("drop: website changed before insert in \(appIdentifier, privacy: .public)")
                await MainActor.run {
                    self.failedCommitEpochs.insert(epoch)
                    self.dismissCommitRemainder(epoch: epoch)
                    if chainEnding { self.clearRequestIdentity() }
                    self.personalization.recordFailed(appIdentifier: appIdentifier)
                    self.lastError = "The website changed before the completion was inserted."
                }
                return
            }
            let expectedTarget = self.activeFocusTarget

            do {
                try await self.inserter.insert(text, appIdentifier: appIdentifier, focusTarget: expectedTarget)
                await MainActor.run {
                    // A stepped insert advances the caret; refresh the active
                    // target deterministically from the approved element/range and
                    // inserted text. Re-reading "whatever is focused now" creates
                    // a race where a newly focused field can become authorized for
                    // the next segment.
                    if keepAccepting {
                        self.activeFocusTarget = Self.targetAfterInsertion(expectedTarget, text: text)
                    }
                    if AppCompatibility.isTerminal(appIdentifier) {
                        // The typed-in completion is now on screen after the
                        // user's keys; the next caret match must include it.
                        TerminalCaret.noteTyped(text)
                    }
                    if chainEnding { self.clearRequestIdentity() }
                    if self.contentLoggingEnabled {
                        self.personalization.recordAccepted(
                            prefix: prefix,
                            completion: text,
                            appIdentifier: appIdentifier
                        )
                    } else {
                        self.personalization.recordMetric(.accepted, appIdentifier: appIdentifier)
                    }
                }
            } catch {
                CotypeLog.loop.error("fail: insert failed in \(appIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.failedCommitEpochs.insert(epoch)
                    self.dismissCommitRemainder(epoch: epoch)
                    if chainEnding { self.clearRequestIdentity() }
                    self.personalization.recordFailed(appIdentifier: appIdentifier)
                    self.lastError = "Could not insert completion: \(error.localizedDescription)"
                }
            }
        }
    }
}

