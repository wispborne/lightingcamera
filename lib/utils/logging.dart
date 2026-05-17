import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

Logger _consoleLogger = Logger();
bool didLoggingInitializeSuccessfully = false;

void configureLogging() {
  _consoleLogger = Logger(
    level: kDebugMode ? Level.debug : Level.error,
    printer: PrettyPrinter(printTime: true),
    output: ConsoleOutput(),
  );

  didLoggingInitializeSuccessfully = true;
}

class Fimber {
  static void v(
    String Function() message, {
    Object? ex,
    StackTrace? stacktrace,
  }) {
    if (!didLoggingInitializeSuccessfully) {
      print(message());
      return;
    }

    _consoleLogger.t(message(), error: ex, stackTrace: stacktrace);
  }

  static void d(String message, {Object? ex, StackTrace? stacktrace}) {
    if (!didLoggingInitializeSuccessfully) {
      print(message);
      return;
    }

    _consoleLogger.d(message, error: ex, stackTrace: stacktrace);
  }

  static void i(String message, {Object? ex, StackTrace? stacktrace}) {
    if (!didLoggingInitializeSuccessfully) {
      print(message);
      return;
    }

    _consoleLogger.i(message, error: ex, stackTrace: stacktrace);
  }

  static void w(String message, {Object? ex, StackTrace? stacktrace}) {
    if (!didLoggingInitializeSuccessfully) {
      print(message);
      return;
    }

    _consoleLogger.w(message, error: ex, stackTrace: stacktrace);
  }

  static void e(String message, {Object? ex, StackTrace? stacktrace}) {
    if (!didLoggingInitializeSuccessfully) {
      print(message);
      return;
    }

    _consoleLogger.e(message, error: ex, stackTrace: stacktrace);
  }
}
