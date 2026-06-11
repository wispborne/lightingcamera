import 'dart:ui' as ui;

/// Which measurement system distances are shown in.
///
/// [system] follows the device's locale (imperial in the few countries that use
/// it, metric everywhere else); [metric] and [imperial] force a choice.
enum UnitSystem { system, metric, imperial }

/// Countries that use imperial / US-customary units for everyday distance.
const _imperialCountries = {'US', 'LR', 'MM'};

/// Whether [system] should render distances in imperial units, resolving
/// [UnitSystem.system] against the device's current locale.
bool usesImperial(UnitSystem system) {
  switch (system) {
    case UnitSystem.metric:
      return false;
    case UnitSystem.imperial:
      return true;
    case UnitSystem.system:
      final country =
          ui.PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
      return country != null && _imperialCountries.contains(country);
  }
}

/// Format a distance given in kilometres for display, switching units and
/// precision so the number stays readable: metres/feet up close, kilometres/
/// miles farther out.
String formatDistanceKm(double km, UnitSystem system) {
  if (usesImperial(system)) {
    final miles = km * 0.621371;
    if (miles < 0.1) {
      return '${(km * 3280.84).round()} ft';
    }
    return '${miles.toStringAsFixed(1)} mi';
  }
  if (km < 1) {
    return '${(km * 1000).round()} m';
  }
  return '${km.toStringAsFixed(1)} km';
}
