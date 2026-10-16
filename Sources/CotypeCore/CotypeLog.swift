import Foundation
import os

/// Content-free diagnostics for the completion loop.
///
/// Every place the loop decides not to show a suggestion logs one short reason
/// here, so "nothing appeared" is always explainable. Messages carry bundle
/// identifiers, strategy names, and counts only: never field text, prompts, or
/// candidates (see CLAUDE.md, "Private data and secrets").
///
/// Watch it live with:
///     log stream --level debug --predicate 'subsystem == "com.tristan.cotype"'
public enum CotypeLog {
    public static let subsystem = "com.tristan.cotype"
    public static let loop = Logger(subsystem: subsystem, category: "loop")
    public static let geometry = Logger(subsystem: subsystem, category: "geometry")
}
