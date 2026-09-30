import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const WeatherApp());
}

Future<http.Response> _getWithRetry(
  Uri uri, {
  Duration timeout = const Duration(seconds: 15),
  int maxAttempts = 2,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await http.get(uri).timeout(timeout);
    } on TimeoutException {
      if (attempt == maxAttempts - 1) {
        throw Exception(
          'Сервер погоды не ответил. Проверьте подключение к интернету и повторите попытку.',
        );
      }
    } on http.ClientException {
      if (attempt == maxAttempts - 1) {
        throw Exception(
          'Не удалось подключиться к серверу. Проверьте интернет и повторите попытку.',
        );
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  throw StateError('Request retry loop completed unexpectedly.');
}

class WeatherApp extends StatelessWidget {
  const WeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Погода',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF102522),
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD8F36A),
          brightness: Brightness.dark,
        ),
      ),
      home: const WeatherScreen(),
    );
  }
}

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  static const _background = Color(0xFF102522);
  static const _muted = Color(0xFFA5B9B1);
  static const _lime = Color(0xFFD8F36A);
  static const _moscowLatitude = 55.7558;
  static const _moscowLongitude = 37.6173;

  Map<String, dynamic>? _weather;
  String? _error;
  String _locationName = 'Ваше местоположение';
  bool _usingMoscowFallback = false;
  bool _usingWttrFallback = false;
  _Place? _selectedPlace;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadWeather();
  }

  Future<void> _loadWeather({bool useDeviceLocation = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      if (useDeviceLocation) _selectedPlace = null;
    });

    try {
      final selectedPlace = useDeviceLocation ? null : _selectedPlace;
      if (selectedPlace != null) {
        await _loadForecast(
          selectedPlace.latitude,
          selectedPlace.longitude,
          locationName: selectedPlace.name,
        );
        return;
      }

      Position? position;
      try {
        position = await _getDevicePosition().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {
        // Use a useful default when location is unavailable or permission is denied.
      }
      final usingFallback = position == null;
      await _loadForecast(
        position?.latitude ?? _moscowLatitude,
        position?.longitude ?? _moscowLongitude,
        locationName: usingFallback ? 'Москва' : 'Ваше местоположение',
        usingMoscowFallback: usingFallback,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<Position> _getDevicePosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Геолокация отключена.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Нет доступа к геолокации.');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 20),
      ),
    );
  }

  Future<void> _loadForecast(
    double latitude,
    double longitude, {
    required String locationName,
    bool usingMoscowFallback = false,
  }) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toString(),
      'longitude': longitude.toString(),
      'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,wind_speed_10m',
      'hourly': 'temperature_2m,weather_code',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset',
      'forecast_days': '5',
      'timezone': 'auto',
    });
    Map<String, dynamic> data;
    var usingWttrFallback = false;
    try {
      final response = await _getWithRetry(
        uri,
        timeout: const Duration(seconds: 4),
        maxAttempts: 1,
      );
      if (response.statusCode != 200) {
        throw Exception('Open-Meteo вернул статус ${response.statusCode}.');
      }
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      data = await _loadWttrForecast(latitude, longitude);
      usingWttrFallback = true;
    }
    data['latitude'] = latitude;
    data['longitude'] = longitude;
    if (mounted) {
      setState(() {
        _weather = data;
        _locationName = locationName;
        _usingMoscowFallback = usingMoscowFallback;
        _usingWttrFallback = usingWttrFallback;
        _loading = false;
      });
    }
  }

  Future<Map<String, dynamic>> _loadWttrForecast(
    double latitude,
    double longitude,
  ) async {
    final uri = Uri.https('wttr.in', '/$latitude,$longitude', {'format': 'j1'});
    final response = await _getWithRetry(
      uri,
      timeout: const Duration(seconds: 4),
      maxAttempts: 1,
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Резервный сервис погоды вернул статус ${response.statusCode}.',
      );
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    final current =
        (result['current_condition'] as List).first as Map<String, dynamic>;
    final days = result['weather'] as List<dynamic>;
    final hourlyTimes = <String>[];
    final hourlyTemperatures = <num>[];
    final hourlyCodes = <int>[];
    final dates = <String>[];
    final highs = <num>[];
    final lows = <num>[];
    final dailyCodes = <int>[];
    final sunrises = <String>[];
    final sunsets = <String>[];

    for (final dayValue in days) {
      final day = dayValue as Map<String, dynamic>;
      final date = day['date'] as String;
      dates.add(date);
      highs.add(_number(day['maxtempC']));
      lows.add(_number(day['mintempC']));
      final hours = day['hourly'] as List<dynamic>;
      final midday = hours.cast<Map<String, dynamic>>().firstWhere(
        (hour) => (_number(hour['time'])).toInt() >= 1200,
        orElse: () => hours.first as Map<String, dynamic>,
      );
      dailyCodes.add(_wttrWeatherCode(midday['weatherCode']));

      for (final hourValue in hours) {
        final hour = hourValue as Map<String, dynamic>;
        final clock = _wttrClock(_number(hour['time']).toInt());
        final timestamp = DateTime.parse('${date}T$clock');
        hourlyTimes.add(timestamp.toIso8601String());
        hourlyTemperatures.add(_number(hour['tempC']));
        hourlyCodes.add(_wttrWeatherCode(hour['weatherCode']));
      }

      final astronomy =
          (day['astronomy'] as List).first as Map<String, dynamic>;
      sunrises.add('${date}T${_wttrSunTime(astronomy['sunrise'] as String)}');
      sunsets.add('${date}T${_wttrSunTime(astronomy['sunset'] as String)}');
    }

    return {
      'current': {
        'time': DateTime.now().toIso8601String(),
        'temperature_2m': _number(current['temp_C']),
        'relative_humidity_2m': _number(current['humidity']),
        'apparent_temperature': _number(current['FeelsLikeC']),
        'is_day': DateTime.now().hour >= 6 && DateTime.now().hour < 20 ? 1 : 0,
        'precipitation': _number(current['precipMM']),
        'weather_code': _wttrWeatherCode(current['weatherCode']),
        'wind_speed_10m': _number(current['windspeedKmph']),
      },
      'hourly': {
        'time': hourlyTimes,
        'temperature_2m': hourlyTemperatures,
        'weather_code': hourlyCodes,
      },
      'daily': {
        'time': dates,
        'weather_code': dailyCodes,
        'temperature_2m_max': highs,
        'temperature_2m_min': lows,
        'sunrise': sunrises,
        'sunset': sunsets,
      },
    };
  }

  double _number(dynamic value) => double.tryParse(value.toString()) ?? 0;

  String _wttrClock(int value) {
    final hour = value ~/ 100;
    final minute = value % 100;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  String _wttrSunTime(String value) {
    final parts = value.split(RegExp(r'[: ]'));
    var hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    final isPm = parts[2] == 'PM';
    if (isPm && hour != 12) hour += 12;
    if (!isPm && hour == 12) hour = 0;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  int _wttrWeatherCode(dynamic value) {
    final code = int.tryParse(value.toString()) ?? -1;
    return switch (code) {
      113 => 0,
      116 => 2,
      119 || 122 => 3,
      143 || 248 || 260 => 45,
      176 ||
      263 ||
      266 ||
      293 ||
      296 ||
      299 ||
      302 ||
      305 ||
      308 ||
      311 ||
      314 ||
      317 ||
      320 ||
      353 ||
      356 ||
      359 ||
      362 ||
      365 => 61,
      179 ||
      182 ||
      185 ||
      227 ||
      230 ||
      281 ||
      284 ||
      323 ||
      326 ||
      329 ||
      332 ||
      335 ||
      338 ||
      350 ||
      368 ||
      371 ||
      374 ||
      377 => 71,
      200 || 386 || 389 || 392 || 395 => 95,
      _ => 3,
    };
  }

  Future<void> _openPlaceSearch() async {
    final place = await showModalBottomSheet<_Place>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _PlaceSearchSheet(),
    );
    if (place == null || !mounted) return;
    setState(() => _selectedPlace = place);
    await _loadWeather();
  }

  @override
  Widget build(BuildContext context) {
    final current = _weather?['current'] as Map<String, dynamic>?;
    final code = current?['weather_code'] as int? ?? 0;
    final isDay = (current?['is_day'] as int? ?? 1) == 1;
    final condition = _condition(code);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: _background,
          backgroundColor: _lime,
          onRefresh: _loadWeather,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildHeader(),
                    const SizedBox(height: 44),
                    if (_loading)
                      const SizedBox(
                        height: 390,
                        child: Center(
                          child: CircularProgressIndicator(color: _lime),
                        ),
                      )
                    else if (_error != null)
                      _buildError()
                    else ...[
                      _buildLocation(),
                      const SizedBox(height: 26),
                      _buildCurrentWeather(current!, condition, code, isDay),
                      const SizedBox(height: 36),
                      _buildSunTimes(),
                      const SizedBox(height: 36),
                      _buildHourlyForecast(),
                      const SizedBox(height: 34),
                      _buildDailyForecast(),
                      const SizedBox(height: 28),
                      Text(
                        _usingWttrFallback
                            ? 'Данные: wttr.in'
                            : 'Данные: Open-Meteo',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() => Row(
    children: [
      const Icon(Icons.location_on_outlined, color: _lime, size: 19),
      const SizedBox(width: 8),
      const Text(
        'ПОГОДА РЯДОМ',
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w700,
        ),
      ),
      const Spacer(),
      IconButton(
        tooltip: 'Найти город или страну',
        onPressed: _loading ? null : _openPlaceSearch,
        icon: const Icon(Icons.search_rounded),
      ),
      IconButton(
        tooltip: 'Моё местоположение',
        onPressed: _loading
            ? null
            : () => _loadWeather(useDeviceLocation: true),
        icon: const Icon(Icons.my_location_rounded),
      ),
      IconButton(
        tooltip: 'Обновить погоду',
        onPressed: _loading ? null : _loadWeather,
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
  );

  Widget _buildLocation() {
    final latitude = (_weather!['latitude'] as num).toStringAsFixed(2);
    final longitude = (_weather!['longitude'] as num).toStringAsFixed(2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_locationName, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 5),
        Text(
          _usingMoscowFallback
              ? 'Геолокация недоступна · город по умолчанию'
              : '$latitude°, $longitude°',
          style: const TextStyle(fontSize: 13, color: _muted),
        ),
      ],
    );
  }

  Widget _buildCurrentWeather(
    Map<String, dynamic> current,
    String condition,
    int code,
    bool isDay,
  ) {
    final temperature = (current['temperature_2m'] as num).round();
    final feelsLike = (current['apparent_temperature'] as num).round();
    final humidity = (current['relative_humidity_2m'] as num).round();
    final wind = (current['wind_speed_10m'] as num).round();
    final precipitation = (current['precipitation'] as num).toStringAsFixed(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '$temperature°',
                style: const TextStyle(
                  fontSize: 104,
                  height: 1,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -5,
                ),
              ),
            ),
            Icon(_weatherIcon(code, isDay), size: 86, color: _lime),
          ],
        ),
        Text(
          condition,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 7),
        Text(
          'Ощущается как $feelsLike°',
          style: const TextStyle(color: _muted, fontSize: 14),
        ),
        const SizedBox(height: 28),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.14)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Metric(
              icon: Icons.water_drop_outlined,
              label: 'Влажность',
              value: '$humidity%',
            ),
            _Metric(
              icon: Icons.air_rounded,
              label: 'Ветер',
              value: '$wind км/ч',
            ),
            _Metric(
              icon: Icons.umbrella_outlined,
              label: 'Осадки',
              value: '$precipitation мм',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSunTimes() {
    final daily = _weather!['daily'] as Map<String, dynamic>;
    final sunrise = _time(daily['sunrise'][0] as String);
    final sunset = _time(daily['sunset'][0] as String);
    return Row(
      children: [
        const Icon(Icons.wb_twilight_rounded, color: _lime, size: 23),
        const SizedBox(width: 11),
        Text('Восход  $sunrise', style: const TextStyle(fontSize: 13)),
        const Spacer(),
        Text('Закат  $sunset', style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  Widget _buildHourlyForecast() {
    final hourly = _weather!['hourly'] as Map<String, dynamic>;
    final times = hourly['time'] as List<dynamic>;
    final temperatures = hourly['temperature_2m'] as List<dynamic>;
    final codes = hourly['weather_code'] as List<dynamic>;
    final currentTime = DateTime.parse(
      (_weather!['current'] as Map<String, dynamic>)['time'] as String,
    );
    var start = times.indexWhere(
      (time) => !DateTime.parse(time as String).isBefore(currentTime),
    );
    if (start < 0) start = 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: 'ПОЧАСОВО'),
        const SizedBox(height: 17),
        SizedBox(
          height: 106,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 8,
            separatorBuilder: (_, _) => const SizedBox(width: 24),
            itemBuilder: (context, index) {
              final hourIndex = start + index;
              if (hourIndex >= times.length) return const SizedBox.shrink();
              final time = DateTime.parse(times[hourIndex] as String);
              return Column(
                children: [
                  Text(
                    index == 0 ? 'Сейчас' : _time(time.toIso8601String()),
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                  const SizedBox(height: 13),
                  Icon(
                    _weatherIcon(
                      codes[hourIndex] as int,
                      time.hour > 6 && time.hour < 20,
                    ),
                    color: _lime,
                    size: 21,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${(temperatures[hourIndex] as num).round()}°',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDailyForecast() {
    final daily = _weather!['daily'] as Map<String, dynamic>;
    final dates = daily['time'] as List<dynamic>;
    final codes = daily['weather_code'] as List<dynamic>;
    final highs = daily['temperature_2m_max'] as List<dynamic>;
    final lows = daily['temperature_2m_min'] as List<dynamic>;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: 'НА 5 ДНЕЙ'),
        const SizedBox(height: 12),
        for (var index = 0; index < dates.length; index++) ...[
          if (index > 0)
            Container(height: 1, color: Colors.white.withValues(alpha: 0.09)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 74,
                  child: Text(
                    index == 0 ? 'Сегодня' : _weekday(dates[index] as String),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                Icon(
                  _weatherIcon(codes[index] as int, true),
                  color: _lime,
                  size: 20,
                ),
                const Spacer(),
                Text(
                  '${(lows[index] as num).round()}°',
                  style: const TextStyle(color: _muted),
                ),
                const SizedBox(width: 18),
                SizedBox(
                  width: 32,
                  child: Text(
                    '${(highs[index] as num).round()}°',
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildError() => SizedBox(
    height: 390,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_searching_rounded, color: _lime, size: 38),
          const SizedBox(height: 18),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _loadWeather,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Попробовать снова'),
            style: FilledButton.styleFrom(
              foregroundColor: _background,
              backgroundColor: _lime,
            ),
          ),
        ],
      ),
    ),
  );

  String _time(String value) => value.split('T').last.substring(0, 5);

  String _weekday(String value) {
    final day = DateTime.parse(value).weekday;
    return const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][day - 1];
  }

  String _condition(int code) => switch (code) {
    0 => 'Ясно',
    1 => 'Преимущественно ясно',
    2 => 'Переменная облачность',
    3 => 'Облачно',
    45 || 48 => 'Туман',
    51 || 53 || 55 || 56 || 57 => 'Морось',
    61 || 63 || 65 || 66 || 67 => 'Дождь',
    71 || 73 || 75 || 77 => 'Снег',
    80 || 81 || 82 => 'Ливень',
    85 || 86 => 'Снегопад',
    95 || 96 || 99 => 'Гроза',
    _ => 'Переменная погода',
  };

  IconData _weatherIcon(int code, bool isDay) => switch (code) {
    0 => isDay ? Icons.wb_sunny_rounded : Icons.nightlight_round,
    1 || 2 => isDay ? Icons.cloud_queue_rounded : Icons.nights_stay_rounded,
    3 || 45 || 48 => Icons.cloud_rounded,
    51 ||
    53 ||
    55 ||
    56 ||
    57 ||
    61 ||
    63 ||
    65 ||
    66 ||
    67 ||
    80 ||
    81 ||
    82 => Icons.water_drop_rounded,
    71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit_rounded,
    95 || 96 || 99 => Icons.thunderstorm_rounded,
    _ => Icons.cloud_queue_rounded,
  };
}

class _Place {
  const _Place({
    required this.name,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.countryCode,
    required this.featureCode,
    this.admin1,
  });

  factory _Place.fromJson(Map<String, dynamic> json) => _Place(
    name: json['name'] as String? ?? 'Без названия',
    country: json['country'] as String? ?? 'Страна не указана',
    admin1: json['admin1'] as String?,
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    countryCode: json['country_code'] as String? ?? '',
    featureCode: json['feature_code'] as String? ?? '',
  );

  final String name;
  final String country;
  final String? admin1;
  final double latitude;
  final double longitude;
  final String countryCode;
  final String featureCode;

  bool get isCountry => featureCode == 'PCLI';

  String get subtitle {
    if (isCountry) return 'Страна';
    return [
      admin1,
      country,
    ].where((part) => part != null && part.isNotEmpty).join(', ');
  }
}

class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet();

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final List<_Place> _places = [];
  Timer? _debounce;
  String? _error;
  String? _countryName;
  String? _countryCode;
  bool _loading = false;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    final requestId = ++_requestId;
    setState(() {
      _places.clear();
      _error = null;
      _loading = query.length >= 2;
    });
    if (query.length < 2) return;
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(query, requestId),
    );
  }

  Future<void> _search(String query, int requestId) async {
    try {
      final parameters = <String, String>{
        'name': query,
        'count': '15',
        'language': 'ru',
        'format': 'json',
      };
      final countryCode = _countryCode;
      if (countryCode != null) parameters['countryCode'] = countryCode;
      final uri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/search',
        parameters,
      );
      final response = await _getWithRetry(
        uri,
        timeout: const Duration(seconds: 8),
        maxAttempts: 1,
      );
      if (response.statusCode != 200) {
        throw Exception('Не удалось выполнить поиск (${response.statusCode}).');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>? ?? const [];
      final places = results
          .map((item) => _Place.fromJson(item as Map<String, dynamic>))
          .toList();
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _places
          ..clear()
          ..addAll(places);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: SizedBox(
          height: availableHeight * 0.78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Страны и города',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть поиск',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_countryName != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _countryName = null;
                        _countryCode = null;
                        _places.clear();
                        _controller.clear();
                      });
                      _focusNode.requestFocus();
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: Text(_countryName!),
                  ),
                ),
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                onSubmitted: (value) {
                  _debounce?.cancel();
                  final query = value.trim();
                  if (query.length >= 2) {
                    _search(query, ++_requestId);
                  }
                },
                decoration: InputDecoration(
                  hintText: _countryName == null
                      ? 'Например, Токио или Япония'
                      : 'Город в $_countryName',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Очистить поиск',
                          onPressed: () {
                            _controller.clear();
                            _onQueryChanged('');
                            _focusNode.requestFocus();
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.07),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFD8F36A)),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    if (_controller.text.trim().length < 2) {
      return Center(
        child: Text(
          _countryName == null
              ? 'Введите название города или страны'
              : 'Введите название города в $_countryName',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFA5B9B1)),
        ),
      );
    }
    if (_places.isEmpty) {
      return const Center(
        child: Text(
          'Ничего не найдено',
          style: TextStyle(color: Color(0xFFA5B9B1)),
        ),
      );
    }
    return ListView.separated(
      itemCount: _places.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
      itemBuilder: (context, index) {
        final place = _places[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            place.isCountry
                ? Icons.public_rounded
                : Icons.location_city_rounded,
            color: Color(0xFFD8F36A),
          ),
          title: Text(place.name),
          subtitle: Text(place.subtitle),
          trailing: Icon(
            place.isCountry
                ? Icons.arrow_forward_ios_rounded
                : Icons.north_east_rounded,
            size: 17,
          ),
          onTap: () {
            if (place.isCountry && place.countryCode.isNotEmpty) {
              setState(() {
                _countryName = place.name;
                _countryCode = place.countryCode;
                _places.clear();
                _controller.clear();
              });
              _focusNode.requestFocus();
            } else {
              Navigator.pop(context, place);
            }
          },
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: const Color(0xFFD8F36A), size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Color(0xFFA5B9B1), fontSize: 11),
          ),
        ],
      ),
      const SizedBox(height: 7),
      Text(
        value,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      color: Color(0xFFA5B9B1),
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    ),
  );
}
