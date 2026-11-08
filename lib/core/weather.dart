import 'dart:convert';

import 'http_get.dart';

class WeatherReport {
  const WeatherReport({
    required this.place,
    required this.temperatureC,
    required this.description,
    this.windKmh,
    this.todayMaxC,
    this.todayMinC,
  });

  final String place;
  final double temperatureC;
  final String description;
  final double? windKmh;
  final double? todayMaxC;
  final double? todayMinC;
}

class WeatherException implements Exception {
  WeatherException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Open-Meteo: geocoding, then the current conditions. No API key (non-commercial use).
class OpenMeteoWeather {
  OpenMeteoWeather(this._get);

  final HttpGet _get;

  Future<WeatherReport> report(String location) async {
    final geo = jsonDecode(await _get(
      'https://geocoding-api.open-meteo.com/v1/search?name=${Uri.encodeQueryComponent(location)}'
      '&count=1&language=ja&format=json',
      const {},
    ));
    final results = geo is Map ? geo['results'] : null;
    final place = results is List && results.isNotEmpty && results.first is Map ? results.first as Map : null;
    if (place == null) throw WeatherException('場所が見つかりません: $location');
    final lat = (place['latitude'] as num).toDouble();
    final lon = (place['longitude'] as num).toDouble();
    final name = <String>{
      for (final key in const ['name', 'admin1', 'country'])
        if (place[key] is String) place[key] as String,
    }.join(', ');

    final forecast = jsonDecode(await _get(
      'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,weather_code,wind_speed_10m'
      '&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto',
      const {},
    ));
    final current = forecast is Map ? forecast['current'] : null;
    if (current is! Map) throw WeatherException('天気を取得できませんでした');
    final daily = forecast['daily'];
    double? firstOf(String key) {
      final list = daily is Map ? daily[key] : null;
      return list is List && list.isNotEmpty && list.first is num ? (list.first as num).toDouble() : null;
    }

    return WeatherReport(
      place: name,
      temperatureC: (current['temperature_2m'] as num).toDouble(),
      description: describe((current['weather_code'] as num?)?.toInt()),
      windKmh: (current['wind_speed_10m'] as num?)?.toDouble(),
      todayMaxC: firstOf('temperature_2m_max'),
      todayMinC: firstOf('temperature_2m_min'),
    );
  }

  /// WMO weather interpretation codes used by Open-Meteo.
  static String describe(int? code) => switch (code) {
        0 => '快晴',
        1 || 2 => '晴れ',
        3 => '曇り',
        45 || 48 => '霧',
        51 || 53 || 55 || 56 || 57 => '霧雨',
        61 || 63 || 65 || 66 || 67 => '雨',
        71 || 73 || 75 || 77 => '雪',
        80 || 81 || 82 => 'にわか雨',
        85 || 86 => 'にわか雪',
        95 || 96 || 99 => '雷雨',
        _ => '不明',
      };
}
