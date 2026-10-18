/// The shared visual primitives: containers, fields and feedback.
///
/// The widgets live in three focused files — [containers.dart] for the card
/// and layout primitives, [fields.dart] for labelled values, and
/// [feedback.dart] for notes, errors, empty states and busy indicators — and
/// are re-exported here so a screen keeps importing a single path.
library;

export 'containers.dart';
export 'feedback.dart';
export 'fields.dart';
