import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:three_js/three_js.dart' as three;

class GameScene extends StatefulWidget {
  const GameScene({super.key});

  @override
  State<GameScene> createState() => _GameSceneState();
}

class _GameSceneState extends State<GameScene> {
  late three.ThreeJS _threeJs;
  late three.Scene _scene;
  late three.PerspectiveCamera _camera;
  late three.Group _playerGroup;
  late three.InstancedMesh _snowSpray;
  final int _maxSnowParticles = 300;
  int _snowParticleIndex = 0;
  int _level = 1;

  // Player parts
  late three.Mesh _leftSki;
  late three.Mesh _rightSki;

  // Humanoid parts
  late three.Group _humanoid;

  // Track (Spur) system
  late three.InstancedMesh _spurMesh;
  int _spurIndex = 0;
  final int _maxSpurs = 4000;
  late three.InstancedMesh _treeMesh;
  final List<three.Vector2> _treePositions = [];
  three.Vector3? _lastSpurPos;
  final double _spurDistThreshold = 0.5;
  final three.Object3D _dummySpur = three.Object3D();

  // Game State
  final three.Vector3 _velocity = three.Vector3(0, 0, 0);
  double _speed = 0.0;
  double _heading = math.pi; // Face downhill (-Z)
  double _roll = 0.0;
  bool _initialized = false;

  // Goal State
  three.Vector3 _goalPos = three.Vector3(150, 0, -5000);
  bool _isGoalReached = false;
  double _remainingTime = 120.0;
  bool _isGameOver = false;
  Timer? _restartTimer;

  // Input
  bool _leftPressed = false;
  bool _rightPressed = false;

  // Terrain constants
  final double _terrainWidth = 3000; // Wider for randomized goal
  final double _terrainDepth = 12000;
  final int _terrainSegments = 200; // Optimized for performance
  final double _courseWidth = 100;

  late FocusNode _focusNode;
  double _lastWidth = 0;
  double _lastHeight = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _threeJs = three.ThreeJS(
      onSetupComplete: () {
        if (mounted) setState(() {});
      },
      setup: _setup,
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _threeJs.dispose();
    super.dispose();
  }

  double _lerp(double a, double b, double t) {
    return a + (b - a) * t;
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) _leftPressed = true;
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _rightPressed = true;
      }
    } else if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _leftPressed = false;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _rightPressed = false;
      }
    }
  }

  Future<void> _setup() async {
    _scene = three.Scene();
    _threeJs.scene = _scene;
    _scene.background = three.Color(0.53, 0.81, 0.92);

    _camera = three.PerspectiveCamera(
      60,
      _threeJs.width / _threeJs.height,
      0.1,
      15000,
    );
    _threeJs.camera = _camera;
    _camera.position.setValues(0, 50, 50);
    _lastWidth = _threeJs.width;
    _lastHeight = _threeJs.height;

    final ambientLight = three.AmbientLight(0xffffff, 0.6);
    _scene.add(ambientLight);

    final dirLight = three.DirectionalLight(0xffffff, 0.8);
    dirLight.position.setValues(100, 200, 100);
    _scene.add(dirLight);

    _createTerrain();
    _createTrees();
    _createSpurSystem();
    _createSnowSpraySystem();
    _createPlayer();
    _createGoalVisual();

    _initialized = true;
    if (mounted) setState(() {});

    _threeJs.addAnimationEvent((dt) {
      if (!_initialized) return;
      if (_threeJs.width != _lastWidth || _threeJs.height != _lastHeight) {
        _lastWidth = _threeJs.width;
        _lastHeight = _threeJs.height;
        _camera.aspect = _threeJs.width / _threeJs.height;
        _camera.updateProjectionMatrix();
      }
      _updatePhysics(dt);
      _updateCamera(dt);
      if (mounted) setState(() {});
    });
  }

  double _getHeight(double x, double z) {
    double baseSlope = z * 0.25;
    // Enhanced hills for better visibility
    double hills = math.sin(x * 0.01) * 15.0 + math.cos(z * 0.01) * 15.0;
    // Enhanced moguls for better visibility
    double moguls =
        math.sin(x * 0.08 + z * 0.04) * 2.0 +
        math.cos(z * 0.1 - x * 0.03) * 2.5 +
        math.sin(x * 0.2 + z * 0.2) * 0.5;
    if (z < -3000) baseSlope += (z + 3000) * 0.3;
    return baseSlope + hills + moguls;
  }

  three.Vector3 _getNormal(double x, double z) {
    const step = 5.0; // Increased step for smoother physics reactions
    final hL = _getHeight(x - step, z);
    final hR = _getHeight(x + step, z);
    final hD = _getHeight(x, z - step);
    final hU = _getHeight(x, z + step);
    final vX = three.Vector3(2 * step, hR - hL, 0);
    final vZ = three.Vector3(0, hU - hD, 2 * step);
    return vZ.clone().cross(vX).normalize();
  }

  void _createTerrain() {
    final geometry = three.PlaneGeometry(
      _terrainWidth,
      _terrainDepth,
      _terrainSegments,
      _terrainSegments,
    );
    geometry.rotateX(-math.pi / 2);
    geometry.translate(0, 0, -_terrainDepth / 2);

    final positions =
        geometry.attributes['position'] as three.Float32BufferAttribute;
    final posArray = positions.array;
    for (int i = 0; i < positions.count; i++) {
      final x = positions.getX(i)!.toDouble();
      final z = positions.getZ(i)!.toDouble();
      posArray[i * 3 + 1] = _getHeight(x, z);
    }
    geometry.computeVertexNormals();
    final material = three.MeshLambertMaterial()..color = three.Color(1, 1, 1);
    _scene.add(three.Mesh(geometry, material));
  }

  void _createTrees() {
    // Clear old tree data if exists
    if (_initialized) {
      _scene.remove(_treeMesh);
      _treeMesh.dispose();
      _treePositions.clear();
    }

    final treeCount = 5000 + (_level - 1) * 5000;
    final treeMat = three.MeshLambertMaterial()..vertexColors = true;

    final List<double> vertices = [], normals = [], colors = [];

    void addPart(three.BufferGeometry geo, List<double> color) {
      final posAttr =
          geo.attributes['position'] as three.Float32BufferAttribute;
      final normAttr = geo.attributes['normal'] as three.Float32BufferAttribute;
      for (int i = 0; i < posAttr.count; i++) {
        vertices.addAll([
          posAttr.getX(i)!.toDouble(),
          posAttr.getY(i)!.toDouble(),
          posAttr.getZ(i)!.toDouble(),
        ]);
        normals.addAll([
          normAttr.getX(i)!.toDouble(),
          normAttr.getY(i)!.toDouble(),
          normAttr.getZ(i)!.toDouble(),
        ]);
        colors.addAll(color);
      }
    }

    final trunkCol = [0.4, 0.2, 0.1],
        leafCol = [0.1, 0.3, 0.1],
        snowCol = [0.95, 0.95, 1.0];

    // 1. Trunk
    addPart(
      three.CylinderGeometry(0.5, 0.5, 4.0, 8)..translate(0, 2, 0),
      trunkCol,
    );

    // 2. Layered Branches and Snow
    for (int i = 0; i < 6; i++) {
      double yPos = 3.5 + i * 2.5;
      double radius = 5.0 - i * 0.7;
      double height = 6.0 - i * 0.5;

      addPart(
        three.ConeGeometry(radius, height, 8)..translate(0, yPos, 0),
        leafCol,
      );
      addPart(
        three.ConeGeometry(radius * 0.95, height * 0.6, 8)
          ..translate(0, yPos + height * 0.25, 0),
        snowCol,
      );
    }

    final posArr = three.Float32Array(vertices.length);
    for (int i = 0; i < vertices.length; i++) {
      posArr[i] = vertices[i];
    }
    final normArr = three.Float32Array(normals.length);
    for (int i = 0; i < normals.length; i++) {
      normArr[i] = normals[i];
    }
    final colArr = three.Float32Array(colors.length);
    for (int i = 0; i < colors.length; i++) {
      colArr[i] = colors[i];
    }

    final treeGeo = three.BufferGeometry();
    treeGeo.attributes['position'] = three.Float32BufferAttribute(posArr, 3);
    treeGeo.attributes['normal'] = three.Float32BufferAttribute(normArr, 3);
    treeGeo.attributes['color'] = three.Float32BufferAttribute(colArr, 3);

    _treeMesh = three.InstancedMesh(treeGeo, treeMat, treeCount);
    final dummy = three.Object3D();
    final random = math.Random();

    for (int i = 0; i < treeCount; i++) {
      double x = (random.nextDouble() - 0.5) * _terrainWidth;
      double z = -random.nextDouble() * _terrainDepth;

      // Keep clear of the course center
      if (x.abs() < _courseWidth) x += (x > 0 ? 100 : -100);

      // CLEARANCE: Skip if too close to the goal
      final distToGoalSq =
          math.pow(x - _goalPos.x, 2) + math.pow(z - _goalPos.z, 2);
      if (distToGoalSq < 1600) {
        // 40 unit radius
        continue;
      }

      _treePositions.add(three.Vector2(x, z));

      dummy.position.setValues(x, _getHeight(x, z), z);
      dummy.rotation.y = random.nextDouble() * math.pi * 2;
      dummy.scale.setScalar(0.7 + random.nextDouble() * 1.0);
      dummy.updateMatrix();
      _treeMesh.setMatrixAt(i, dummy.matrix);
    }
    _treeMesh.instanceMatrix!.needsUpdate = true;
    _treeMesh.frustumCulled = false;
    _scene.add(_treeMesh);
  }

  void _createSpurSystem() {
    final spurGeo = three.PlaneGeometry(0.3, 0.8)..rotateX(-math.pi / 2);
    final spurMat = three.MeshBasicMaterial()
      ..color = three.Color(0.8, 0.8, 0.8)
      ..transparent = true
      ..opacity = 0.4;
    _spurMesh = three.InstancedMesh(spurGeo, spurMat, _maxSpurs);
    _scene.add(_spurMesh);
  }

  void _createPlayer() {
    _playerGroup = three.Group();
    _scene.add(_playerGroup);
    _humanoid = three.Group()..visible = false; // Hide body in POV
    _playerGroup.add(_humanoid);

    final jacketMat = three.MeshLambertMaterial()
      ..color = three.Color(0.1, 0.4, 0.9);
    final pantsMat = three.MeshLambertMaterial()
      ..color = three.Color(0.15, 0.15, 0.15);
    final fleshMat = three.MeshLambertMaterial()
      ..color = three.Color(0.95, 0.75, 0.65);
    final bootMat = three.MeshLambertMaterial()
      ..color = three.Color(0.2, 0.2, 0.3);

    _humanoid.add(
      three.Mesh(three.BoxGeometry(1.6, 2.4, 1.0), jacketMat)..position.y = 2.6,
    );
    final head = three.Group()..position.y = 4.0;
    head.add(three.Mesh(three.BoxGeometry(0.8, 0.8, 0.8), fleshMat));
    head.add(
      three.Mesh(
        three.BoxGeometry(0.85, 0.5, 0.85),
        three.MeshLambertMaterial()..color = three.Color(1, 1, 0),
      )..position.y = 0.3,
    );
    _humanoid.add(head);

    final legGeo = three.BoxGeometry(0.7, 2.4, 0.7);
    _humanoid.add(
      three.Mesh(legGeo, pantsMat)..position.setValues(-0.5, 1.2, 0),
    );
    _humanoid.add(
      three.Mesh(legGeo, pantsMat)..position.setValues(0.5, 1.2, 0),
    );
    final bootGeo = three.BoxGeometry(0.8, 0.6, 1.2);
    _humanoid.add(
      three.Mesh(bootGeo, bootMat)..position.setValues(-0.5, 0.3, 0.2),
    );
    _humanoid.add(
      three.Mesh(bootGeo, bootMat)..position.setValues(0.5, 0.3, 0.2),
    );

    final skiGeo = three.BoxGeometry(0.6, 0.2, 9.0);
    final skiMat = three.MeshBasicMaterial()..color = three.Color(1, 0.1, 0.1);
    // Position skis so they sit on the snow and are visible in POV
    _leftSki = three.Mesh(skiGeo, skiMat)..position.setValues(-0.8, 0.1, -4.5);
    _rightSki = three.Mesh(skiGeo, skiMat)..position.setValues(0.8, 0.1, -4.5);
    _playerGroup.add(_leftSki);
    _playerGroup.add(_rightSki);

    _playerGroup.position.setValues(0, _getHeight(0, 0), 0);
    final random = math.Random();
    final randomX =
        (random.nextDouble() - 0.5) * 2000; // Random X between -1000 and 1000
    _goalPos = three.Vector3(randomX, _getHeight(randomX, -5000), -5000);
  }

  void _createGoalVisual() {
    final pillar = three.Mesh(
      three.CylinderGeometry(10, 10, 500, 16),
      three.MeshBasicMaterial()
        ..color = three.Color(1, 0.2, 0.2)
        ..transparent = true
        ..opacity = 0.4,
    );
    pillar.position.setFrom(_goalPos).y += 250;
    _scene.add(pillar);

    final flag = three.Group()..position.setFrom(_goalPos);
    flag.add(
      three.Mesh(
        three.CylinderGeometry(0.5, 0.5, 30, 8),
        three.MeshLambertMaterial()..color = three.Color(0.8, 0.8, 0.8),
      )..position.y = 15,
    );
    flag.add(
      three.Mesh(
        three.BoxGeometry(10, 6, 0.5),
        three.MeshLambertMaterial()..color = three.Color(1, 0, 0),
      )..position.setValues(5, 25, 0),
    );
    _scene.add(flag);
  }

  void _updatePhysics(double dt) {
    final pos = _playerGroup.position;
    final normal = _getNormal(pos.x, pos.z);
    final slopeForce = three.Vector3(
      0,
      -9.8,
      0,
    ).sub(normal.clone().scale(three.Vector3(0, -9.8, 0).dot(normal)));
    _velocity.add(slopeForce.scale(dt * 5.0));

    double turnRate = 6.0 * dt;
    if (_leftPressed) _heading += turnRate;
    if (_rightPressed) _heading -= turnRate;
    _velocity.scale(0.997);

    final facingDir = three.Vector3(math.sin(_heading), 0, math.cos(_heading));
    double alignment = facingDir.dot(three.Vector3(0, 0, -1)).abs();
    if (alignment > 0.6) {
      _velocity.add(slopeForce.scale(dt * 8.0 * alignment));
    } else {
      _velocity.scale(1.0 - (1.0 - alignment) * dt * 4.0);
    }

    _speed = _velocity.length;
    if (_speed < 1.0) _velocity.z -= 1.0;

    if (_leftPressed || _rightPressed) {
      _velocity.applyAxisAngle(
        three.Vector3(0, 1, 0),
        (_leftPressed ? 1 : -1) * 1.5 * dt,
      );
      _roll = _lerp(_roll, (_leftPressed ? 1 : -1) * 0.4, dt * 5);
    } else {
      _roll = _lerp(_roll, 0, dt * 5);
    }

    _playerGroup.position.add(_velocity.clone().scale(dt));

    // Collision Check: Trees
    for (final treePos in _treePositions) {
      // Basic distance check (ignoring Y for simplicity)
      final dx = _playerGroup.position.x - treePos.x;
      final dz =
          _playerGroup.position.z - treePos.y; // Vector2.y is Z in our 3D world
      if (dx * dx + dz * dz < 4.0) {
        // 2.0 unit radius
        _velocity.scale(0.8); // 20% speed reduction per frame of overlap
        _speed = _velocity.length;
      }
    }

    if (_velocity.length > 1.0) _heading = math.atan2(_velocity.x, _velocity.z);
    _playerGroup.position.y = _getHeight(
      _playerGroup.position.x,
      _playerGroup.position.z,
    );

    if (_velocity.length > 0.01) {
      _playerGroup.up.lerp(normal, dt * 5);
      _playerGroup.lookAt(_playerGroup.position.clone().add(_velocity));
      _playerGroup.rotateZ(_roll);
      _humanoid.rotation.z = _roll * 0.5;
      _humanoid.rotation.x = _speed * 0.01;
      _updateSpurs(normal);
      _updateSnowSpray(normal);
    }

    if (!_isGoalReached && !_isGameOver) {
      final dist = _playerGroup.position.distanceTo(_goalPos);

      _remainingTime -= dt;
      if (_remainingTime <= 0) {
        _remainingTime = 0;
        _isGameOver = true;
        _startAutoRestart();
      } else if (dist < 20.0) {
        _isGoalReached = true;
        _level++; // Progression
        _startAutoRestart();
      } else if (_playerGroup.position.z < -5050) {
        // Passed the goal line
        _isGameOver = true;
        _startAutoRestart();
      }
    }
  }

  void _startAutoRestart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _restartGame();
    });
  }

  void _restartGame() {
    setState(() {
      _isGoalReached = false;
      _isGameOver = false;
      _playerGroup.position.setValues(0, _getHeight(0, 0), 0);
      _velocity.setValues(0, 0, 0);
      _heading = math.pi;

      // Time Limit Logic
      double timeLimit = 120.0 - (_level - 1) * 5.0;
      if (timeLimit < 80.0) timeLimit = 80.0;
      _remainingTime = timeLimit;

      // Standardize goal distance to 5000, randomize X position per level
      final random = math.Random();
      final randomX = (random.nextDouble() - 0.5) * 2000;
      const dist = 5000.0;
      _goalPos = three.Vector3(randomX, _getHeight(randomX, -dist), -dist);

      // Update visual goal
      _scene.children
          .where(
            (c) =>
                c is three.Group ||
                (c is three.Mesh && c.geometry is three.CylinderGeometry),
          )
          .forEach((c) {
            // Find markers that are part of the goal visual (pillars or flags)
            // They are usually positioned far down the slope
            if (c.position.z < -1000) {
              c.position.setFrom(_goalPos);
              if (c.geometry is three.CylinderGeometry) c.position.y += 250;
            }
          });
    });
    _createTrees();
  }

  void _updateSpurs(three.Vector3 normal) {
    if (_lastSpurPos == null) {
      _lastSpurPos = _playerGroup.position.clone();
      return;
    }
    if (_playerGroup.position.distanceTo(_lastSpurPos!) > _spurDistThreshold) {
      _lastSpurPos!.setFrom(_playerGroup.position);
      final quat = _playerGroup.quaternion;
      _placeSpur(
        _playerGroup.position.clone().add(
          three.Vector3(0.4, 0, 0).applyQuaternion(quat),
        ),
        normal,
      );
      _placeSpur(
        _playerGroup.position.clone().add(
          three.Vector3(-0.4, 0, 0).applyQuaternion(quat),
        ),
        normal,
      );
      _spurMesh.instanceMatrix!.needsUpdate = true;
    }
  }

  void _placeSpur(three.Vector3 pos, three.Vector3 normal) {
    _dummySpur.position.setFrom(pos).y += 0.4;
    _dummySpur.up.setFrom(normal);
    _dummySpur.lookAt(pos.clone().add(_velocity));
    _dummySpur.updateMatrix();
    _spurMesh.setMatrixAt(_spurIndex, _dummySpur.matrix);
    _spurIndex = (_spurIndex + 1) % _maxSpurs;
  }

  void _createSnowSpraySystem() {
    _snowSpray = three.InstancedMesh(
      three.BoxGeometry(0.5, 0.5, 0.5),
      three.MeshBasicMaterial()
        ..color = three.Color(1, 1, 1)
        ..transparent = true
        ..opacity = 0.5,
      _maxSnowParticles,
    );
    _scene.add(_snowSpray);
    final dummy = three.Object3D()..scale.setScalar(0);
    for (int i = 0; i < _maxSnowParticles; i++) {
      dummy.updateMatrix();
      _snowSpray.setMatrixAt(i, dummy.matrix);
    }
  }

  void _updateSnowSpray(three.Vector3 normal) {
    if (_speed < 5.0 || _roll.abs() < 0.1) return;
    final dummy = three.Object3D();
    final random = math.Random();
    for (int i = 0; i < 3; i++) {
      final pos = _playerGroup.position.clone().add(
        three.Vector3(
          (_roll > 0 ? -1 : 1) * 3.0,
          0.6,
          -2.0,
        ).applyQuaternion(_playerGroup.quaternion),
      );
      dummy.position.setFrom(pos)
        ..x += (random.nextDouble() - 0.5) * 2.0
        ..y += random.nextDouble() * 2.5;
      dummy.scale.setScalar(1 + random.nextDouble() * 2.0);
      dummy.rotation.set(
        random.nextDouble(),
        random.nextDouble(),
        random.nextDouble(),
      );
      dummy.updateMatrix();
      _snowSpray.setMatrixAt(_snowParticleIndex, dummy.matrix);
      _snowParticleIndex = (_snowParticleIndex + 1) % _maxSnowParticles;
    }
    _snowSpray.instanceMatrix!.needsUpdate = true;
  }

  void _updateCamera(double dt) {
    // POV: Position camera at higher eye level to prevent clipping
    final headHeight = 6.0;
    final targetPos = _playerGroup.position.clone().add(
      three.Vector3(0, headHeight, 0),
    );

    // Guard: Prevent camera from going under terrain (strengthened)
    final groundH = _getHeight(targetPos.x, targetPos.z);
    if (targetPos.y < groundH + 4.0) targetPos.y = groundH + 4.0;

    _camera.position.setFrom(targetPos);

    // Look ahead and down to see the skis from the higher view
    final lookAtPos = _playerGroup.position.clone().add(
      three.Vector3(math.sin(_heading) * 10, 2.0, math.cos(_heading) * 10),
    );
    _camera.lookAt(lookAtPos);

    // Apply slight roll to the camera for immersion
    _camera.rotation.z = _roll * -0.5;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;

    return Stack(
      children: [
        KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: GestureDetector(
            onTap: () => _focusNode.requestFocus(),
            child: _threeJs.build(),
          ),
        ),
        if (!_initialized)
          Container(
            color: Colors.white,
            child: const Center(child: CircularProgressIndicator()),
          ),
        if (_initialized)
          SafeArea(
            child: Stack(
              children: [
                Positioned(top: 20, left: 20, child: _buildInfoPanel()),
                Positioned(top: 20, right: 20, child: _buildSpeedometer()),
                Positioned(
                  top: isLandscape ? 10 : 40,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildNavigationArrow()),
                ),
                if (_isGoalReached) _buildGoalOverlay(),
                if (_isGameOver) _buildGameOverOverlay(),
                _buildTouchControls(isLandscape),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildInfoPanel() {
    int minutes = _remainingTime ~/ 60;
    int seconds = (_remainingTime % 60).toInt();
    String timeStr = '$minutes:${seconds.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.black54,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Level: $_level',
            style: const TextStyle(
              color: Colors.orangeAccent,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          Text(
            'Time: $timeStr',
            style: TextStyle(
              color: _remainingTime < 10.0 ? Colors.redAccent : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedometer() {
    double speedKmh = _speed * 1.2;
    double normalized = (speedKmh / 120.0 * 100).clamp(0, 100);
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 2),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: normalized / 100,
            strokeWidth: 6,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation(
              speedKmh > 120 ? Colors.orangeAccent : Colors.cyanAccent,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                speedKmh.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text(
                'km/h',
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationArrow() {
    final diff = _goalPos.clone().sub(_playerGroup.position);
    // Reversed: heading - angleToGoal or similar logic to match Flutter's clockwise rotation
    final relativeAngle = _heading - math.atan2(diff.x, diff.z);
    return Column(
      children: [
        const Text(
          'GOAL',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Transform.rotate(
          angle: relativeAngle,
          child: const Icon(
            Icons.arrow_upward,
            color: Colors.redAccent,
            size: 60,
          ),
        ),
        Text(
          '${(_playerGroup.position.distanceTo(_goalPos) / 10).toStringAsFixed(0)} m',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildGoalOverlay() => Container(
    color: Colors.black45,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'GOAL!!',
            style: TextStyle(
              color: Colors.yellowAccent,
              fontSize: 80,
              fontWeight: FontWeight.bold,
              fontStyle: FontStyle.italic,
              shadows: [Shadow(color: Colors.black, blurRadius: 10)],
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Restarting in 3 seconds...',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _restartTimer?.cancel();
              _restartGame();
            },
            child: const Text('Restart Now'),
          ),
        ],
      ),
    ),
  );

  Widget _buildGameOverOverlay() => Container(
    color: Colors.red.withOpacity(0.3),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _remainingTime <= 0 ? 'TIME UP' : 'GAME OVER',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 80,
              fontWeight: FontWeight.bold,
              fontStyle: FontStyle.italic,
              shadows: [Shadow(color: Colors.black, blurRadius: 10)],
            ),
          ),
          Text(
            _remainingTime <= 0 ? 'Out of time!' : 'You missed the goal!',
            style: const TextStyle(color: Colors.white, fontSize: 24),
          ),
          const SizedBox(height: 10),
          const Text(
            'Restarting in 3 seconds...',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              _restartTimer?.cancel();
              _restartGame();
            },
            child: const Text('Restart Now'),
          ),
        ],
      ),
    ),
  );

  Future<void> _showRestartConfirmDialog() async {
    final shouldRestart = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart Game'),
        content: const Text('Are you sure you want to restart?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    if (shouldRestart == true) {
      _restartGame();
    }
  }

  Widget _buildTouchControls(bool isLandscape) {
    return Positioned(
      bottom: isLandscape ? 20 : 40,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isLandscape ? 60 : 40),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildRoundButton(
              isPressed: _leftPressed,
              onPressed: (val) => setState(() => _leftPressed = val),
              icon: Icons.arrow_back_ios_new,
            ),
            ElevatedButton(
              onPressed: _showRestartConfirmDialog,
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(16),
                backgroundColor: Colors.white.withOpacity(0.8),
              ),
              child: const Icon(Icons.refresh, color: Colors.black87, size: 28),
            ),
            _buildRoundButton(
              isPressed: _rightPressed,
              onPressed: (val) => setState(() => _rightPressed = val),
              icon: Icons.arrow_forward_ios,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoundButton({
    required bool isPressed,
    required Function(bool) onPressed,
    required IconData icon,
  }) {
    return Listener(
      onPointerDown: (_) => onPressed(true),
      onPointerUp: (_) => onPressed(false),
      onPointerCancel: (_) => onPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: isPressed ? const Color(0xFFB2EBF2) : const Color(0xFFE0F7FA),
          shape: BoxShape.circle,
          boxShadow: isPressed
              ? [
                  // Simulating inset/sunken look with subtle inner shadows
                  const BoxShadow(
                    color: Colors.white70,
                    offset: Offset(2, 2),
                    blurRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    offset: const Offset(-2, -2),
                    blurRadius: 2,
                  ),
                ]
              : [
                  // Raised (neumorphic)
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    offset: const Offset(5, 5),
                    blurRadius: 10,
                  ),
                  BoxShadow(
                    color: Colors.white.withOpacity(0.9),
                    offset: const Offset(-5, -5),
                    blurRadius: 10,
                  ),
                ],
        ),
        child: Center(child: Icon(icon, color: Colors.cyan.shade800, size: 32)),
      ),
    );
  }
}
