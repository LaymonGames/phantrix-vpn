import 'redactor.dart';

enum LogLevel {
	trace(0),
	debug(1),
	info(2),
	warning(3),
	error(4),
	off(5);

	const LogLevel(this.weight);

	final int weight;
}

class LogRecord {
	const LogRecord({
		required this.level,
		required this.tag,
		required this.message,
		required this.timestamp,
		this.fields,
	});

	final LogLevel level;
	final String tag;
	final String message;
	final DateTime timestamp;
	final Map<String, Object?>? fields;

	String format() {
		final time = timestamp.toUtc().toIso8601String();
		final fields = this.fields;
		final suffix = fields == null || fields.isEmpty
			? ''
			: ' | ${fields.entries.map((e) => '${e.key}=${Redactor.redact(e.value)}').join(' ')}';
		return '$time ${level.name.toUpperCase()} [$tag] $message$suffix';
	}
}

typedef LogSink = void Function(LogRecord record);

/// Structured, redacting logger.
///
/// Two sinks are always available: an in-memory ring buffer (bounded, used by
/// the in-app log viewer) and an optional external sink (stderr / file) that
/// the host application installs. Records are redacted at the boundary, so a
/// sink can never receive a secret.
class Logger {
	Logger({required this.tag, int bufferSize = 512})
		: _buffer = <LogRecord>[],
		  _bufferSize = bufferSize;

	final String tag;
	final List<LogRecord> _buffer;
	final int _bufferSize;

	static LogLevel minLevel = LogLevel.info;
	static bool redactEnabled = true;
	static LogSink? external;
	static bool mirrorExternal = false;

	List<LogRecord> get buffer => List.unmodifiable(_buffer);

	void clear() => _buffer.clear();

	void trace(String message, {Map<String, Object?>? fields}) =>
		_log(LogLevel.trace, message, fields);

	void debug(String message, {Map<String, Object?>? fields}) =>
		_log(LogLevel.debug, message, fields);

	void info(String message, {Map<String, Object?>? fields}) =>
		_log(LogLevel.info, message, fields);

	void warning(String message, {Map<String, Object?>? fields}) =>
		_log(LogLevel.warning, message, fields);

	void error(String message, {Map<String, Object?>? fields}) =>
		_log(LogLevel.error, message, fields);

	void _log(LogLevel level, String message, Map<String, Object?>? fields) {
		if (level.weight < minLevel.weight) {
			return;
		}
		final record = LogRecord(
			level: level,
			tag: tag,
			message: message,
			timestamp: DateTime.now(),
			fields: redactEnabled ? _redactFields(fields) : fields,
		);
		_buffer.add(record);
		if (_buffer.length > _bufferSize) {
			_buffer.removeRange(0, _buffer.length - _bufferSize);
		}
		final sink = external;
		if (sink != null) {
			sink(record);
		}
	}

	static Map<String, Object?>? _redactFields(Map<String, Object?>? fields) {
		if (fields == null) {
			return null;
		}
		return fields.map((key, value) => MapEntry(key, Redactor.redact(value)));
	}
}

/// Named logger factory so tags are stable and greppable.
Logger loggerFor(String tag) => Logger(tag: tag);
