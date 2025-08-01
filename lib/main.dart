import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:geolocator/geolocator.dart' as geolocator;
import 'package:geotypes/src/geojson.dart' as geojson;
import 'package:turf/turf.dart' as turf;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  final accessToken = dotenv.env['MAPBOX_ACCESS_TOKEN'];
  if (accessToken == null || accessToken.isEmpty) {
    throw Exception('MAPBOX_ACCESS_TOKEN is missing in .env file');
  }
  mapbox.MapboxOptions.setAccessToken(accessToken);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Static Polygon Geofencing',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const GeofenceHomeScreen(),
    );
  }
}

class GeofenceHomeScreen extends StatefulWidget {
  const GeofenceHomeScreen({super.key});
  @override
  State<GeofenceHomeScreen> createState() => _GeofenceHomeScreenState();
}

class _GeofenceHomeScreenState extends State<GeofenceHomeScreen> {
  late mapbox.MapboxMap mapboxMap;

  mapbox.PointAnnotationManager? pointAnnotationManager;
  mapbox.PointAnnotation? currentLocationAnnotation;

  final String _sourceId = "home_polygon_source";
  final String _fillLayerId = "home_polygon_fill";

  final List<geojson.Point> homePolygon = [
    geojson.Point(coordinates: geojson.Position(76.8358, 30.6633)),
    geojson.Point(coordinates: geojson.Position(76.8361, 30.6633)),
    geojson.Point(coordinates: geojson.Position(76.8361, 30.6636)),
    geojson.Point(coordinates: geojson.Position(76.8358, 30.6636)),
  ];

  StreamSubscription<geolocator.Position>? _positionStream;

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  bool _wasInsidePolygon = true;
  final double shrinkFactor = 0.5;
  List<mapbox.Position> userPath = [];

  @override
  void initState() {
    super.initState();
    _initializeNotifications().then((_) {
      _showNotification("App started - notification test");
    });
    _checkAndRequestPermissions();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  Future<void> _initializeNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(settings);
  }

  Future<void> _showNotification(String message) async {
    const androidDetails = AndroidNotificationDetails(
      'geofence_channel',
      'Geofence Notifications',
      channelDescription: 'Notifications for geofence enter/exit',
      importance: Importance.max,
      priority: Priority.high,
    );
    const notificationDetails = NotificationDetails(android: androidDetails);
    await _localNotifications.show(0, 'Geofence Alert', message, notificationDetails);
  }

  geojson.Position _calculateCentroid(List<geojson.Point> polygon) {
    double sumLng = 0;
    double sumLat = 0;
    for (final point in polygon) {
      sumLng += point.coordinates.lng;
      sumLat += point.coordinates.lat;
    }
    return geojson.Position(sumLng / polygon.length, sumLat / polygon.length);
  }

  List<geojson.Point> _shrinkPolygon(List<geojson.Point> polygon, double factor) {
    final centroid = _calculateCentroid(polygon);
    return polygon.map((point) {
      final lng = centroid.lng + (point.coordinates.lng - centroid.lng) * factor;
      final lat = centroid.lat + (point.coordinates.lat - centroid.lat) * factor;
      return geojson.Point(coordinates: geojson.Position(lng, lat));
    }).toList();
  }

  Future<void> _checkAndRequestPermissions() async {
    PermissionStatus locationStatus = await Permission.location.status;
    if (locationStatus.isDenied) {
      locationStatus = await Permission.location.request();
    }
    if (locationStatus.isDenied) {
      _showPermissionDeniedDialog("Location permission is required to use this app.");
      return;
    }
    if (locationStatus.isPermanentlyDenied) {
      _showOpenAppSettingsDialog("Location permission is permanently denied. Please enable it in app settings.");
      return;
    }

    if (await Permission.locationAlways.isDenied) {
      final backgroundStatus = await Permission.locationAlways.request();
      if (backgroundStatus.isDenied) {
        debugPrint('Background location permission denied.');
      }
      if (backgroundStatus.isPermanentlyDenied) {
        _showOpenAppSettingsDialog("Background Location permission is permanently denied. Please enable it in app settings.");
      }
    }

    await _initializeInsideOutside();
    _startLocationUpdates();
  }

  Future<void> _initializeInsideOutside() async {
    try {
      final pos = await geolocator.Geolocator.getCurrentPosition();
      final turf.Position userPos = turf.Position(pos.longitude, pos.latitude);
      final smallerPolygon = _shrinkPolygon(homePolygon, shrinkFactor);
      final List<turf.Position> polygonPositions = smallerPolygon
          .map((p) => turf.Position(p.coordinates.lng, p.coordinates.lat))
          .toList();
      final polygonFeature = turf.Feature(
        geometry: turf.Polygon(coordinates: [polygonPositions]),
      );
      _wasInsidePolygon = turf.booleanPointInPolygon(userPos, polygonFeature);
      debugPrint('Initial inside polygon: $_wasInsidePolygon');
    } catch (e) {
      debugPrint('Error initializing inside/outside polygon state: $e');
    }
  }

  void _showPermissionDeniedDialog(String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Permission Denied'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _checkAndRequestPermissions();
              },
              child: const Text('Retry')),
          TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showOpenAppSettingsDialog(String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Permission Required'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.of(context).pop();
            },
            child: const Text('Open Settings'),
          ),
          TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _startLocationUpdates() async {
    final serviceEnabled = await geolocator.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled.');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please enable location services'),
      ));
      return;
    }

    _positionStream = geolocator.Geolocator.getPositionStream(
      locationSettings: const geolocator.LocationSettings(
        accuracy: geolocator.LocationAccuracy.best,
        distanceFilter: 5,
      ),
    ).listen((position) async {

      final currentPos = mapbox.Position(position.longitude.toDouble(), position.latitude.toDouble());

      setState(() {
        userPath.add(currentPos);
      });

      _evaluateGeofence(position);
      _moveCameraToPosition(position);
      await _updateUserPathLine();
      await _updateCurrentLocationMarker(currentPos);
    });
  }

  void _evaluateGeofence(geolocator.Position position) {
    final turf.Position userPosition = turf.Position(position.longitude.toDouble(), position.latitude.toDouble());

    final smallerPolygon = _shrinkPolygon(homePolygon, shrinkFactor);

    final List<turf.Position> polygonPositions = smallerPolygon
        .map((p) => turf.Position(p.coordinates.lng.toDouble(), p.coordinates.lat.toDouble()))
        .toList();

    final turf.Feature<turf.Polygon> polygonFeature = turf.Feature(
      geometry: turf.Polygon(coordinates: [polygonPositions]),
    );

    final bool isInside = turf.booleanPointInPolygon(userPosition, polygonFeature);

    debugPrint('User position: (${position.latitude}, ${position.longitude}), isInside: $isInside, previous: $_wasInsidePolygon');

    if (_wasInsidePolygon && !isInside) {
      debugPrint('User exited polygon - showing notification');
      _showNotification("You have exited your home boundary.");
    } else if (!_wasInsidePolygon && isInside) {
      debugPrint('User entered polygon - showing notification');
      _showNotification("You have entered your home boundary.");
    }

    _wasInsidePolygon = isInside;
  }

  void _moveCameraToPosition(geolocator.Position position) {
    try {
      mapboxMap.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(position.longitude.toDouble(), position.latitude.toDouble()),
          ),
          zoom: 18,
        ),
      );
    } catch (e) {
      debugPrint('Mapbox setCamera error: $e');
    }
  }

  Future<void> _addPolygonToMap() async {
    final smallerPolygon = _shrinkPolygon(homePolygon, shrinkFactor);

    if (smallerPolygon.length < 3) {
      debugPrint("Polygon must have at least 3 points");
      return;
    }

    // IMPORTANT FIX: Make sure polygon coordinates array is well formed
    final List<List<double>> coords = [
      ...smallerPolygon.map((p) => [p.coordinates.lng.toDouble(), p.coordinates.lat.toDouble()]),
      [smallerPolygon[0].coordinates.lng.toDouble(), smallerPolygon[0].coordinates.lat.toDouble()], // Close polygon
    ];

    final geoJsonData = {
      "type": "Feature",
      "geometry": {
        "type": "Polygon",
        "coordinates": [coords],
      },
      "properties": {},
    };

    final geoJsonString = jsonEncode(geoJsonData);

    debugPrint('Polygon GeoJSON: $geoJsonString');

    try {
      if (await mapboxMap.style.styleLayerExists(_fillLayerId)) {
        await mapboxMap.style.removeStyleLayer(_fillLayerId);
      }
    } catch (_) {}

    try {
      if (await mapboxMap.style.styleSourceExists(_sourceId)) {
        await mapboxMap.style.removeStyleSource(_sourceId);
      }
    } catch (_) {}

    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(id: _sourceId, data: geoJsonString),
    );

    await mapboxMap.style.addLayer(
      mapbox.FillLayer(
        id: _fillLayerId,
        sourceId: _sourceId,
        fillColor: const Color(0xFF3BB2D0).value, // cyan-ish fill color
        fillOutlineColor: const Color(0xFF3887BE).value, // darker outline
        fillOpacity: 0.6,
      ),
    );
  }

  Future<void> _updateUserPathLine() async {
    const String lineSourceId = 'user_path_source';
    const String lineLayerId = 'user_path_layer';

    try {
      if (await mapboxMap.style.styleLayerExists(lineLayerId)) {
        await mapboxMap.style.removeStyleLayer(lineLayerId);
      }
    } catch (_) {}

    try {
      if (await mapboxMap.style.styleSourceExists(lineSourceId)) {
        await mapboxMap.style.removeStyleSource(lineSourceId);
      }
    } catch (_) {}

    if (userPath.length < 2) {
      return;
    }

    final coords = userPath.map((pos) => [pos.lng, pos.lat]).toList();

    final geoJsonLine = jsonEncode({
      "type": "Feature",
      "geometry": {
        "type": "LineString",
        "coordinates": coords,
      },
      "properties": {},
    });

    await mapboxMap.style.addSource(
      mapbox.GeoJsonSource(id: lineSourceId, data: geoJsonLine),
    );

    await mapboxMap.style.addLayer(
      mapbox.LineLayer(
        id: lineLayerId,
        sourceId: lineSourceId,
        lineColor: 0xFF007AFF,
        lineWidth: 4,
      ),
    );
  }

  Future<void> _updateCurrentLocationMarker(mapbox.Position position) async {
    if (pointAnnotationManager == null) {
      pointAnnotationManager = await mapboxMap.annotations.createPointAnnotationManager();
    }

    if (currentLocationAnnotation != null) {
      await pointAnnotationManager!.delete(currentLocationAnnotation!);
      currentLocationAnnotation = null;
    }

    currentLocationAnnotation = await pointAnnotationManager!.create(
      mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: position),
        iconImage: "marker-15", // Mapbox default marker icon
        iconSize: 1.5,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final center = mapbox.Point(
      coordinates: mapbox.Position(76.8359, 30.66345),
    );

    return Scaffold(
      appBar: AppBar(title: const Text("Static Polygon Geofencing")),
      body: mapbox.MapWidget(
        key: const ValueKey("mapWidget"),
        cameraOptions: mapbox.CameraOptions(center: center, zoom: 18),
        onMapCreated: (controller) async {
          mapboxMap = controller;
          await _addPolygonToMap();
        },
      ),
    );
  }
}
