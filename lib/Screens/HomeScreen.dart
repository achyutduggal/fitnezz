import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:convert';
import 'dart:io';

// Database helper class
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('food_log.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE food_logs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        food_name TEXT NOT NULL,
        calories REAL NOT NULL,
        date_time TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertFoodLog(String foodName, double calories) async {
    final db = await database;
    final data = {
      'food_name': foodName,
      'calories': calories,
      'date_time': DateTime.now().toIso8601String(),
    };
    return await db.insert('food_logs', data);
  }

  Future<List<Map<String, dynamic>>> getFoodLogs() async {
    final db = await database;
    return await db.query('food_logs', orderBy: 'date_time DESC');
  }
}

class CalorieTrackerScreen extends StatefulWidget {
  @override
  _CalorieTrackerScreenState createState() => _CalorieTrackerScreenState();
}

class _CalorieTrackerScreenState extends State<CalorieTrackerScreen> {
  File? _selectedImage;
  String _detectedFood = '';
  double _calories = 0.0;
  bool _isLoading = false;
  Interpreter? _interpreter;
  List<String>? _labels;
  List<Map<String, dynamic>> _foodLogs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadModel();
      loadFoodLogs();
    });
  }

  Future<void> loadFoodLogs() async {
    final logs = await DatabaseHelper.instance.getFoodLogs();
    setState(() {
      _foodLogs = logs;
    });
  }

  Future<void> logFood() async {
    if (_detectedFood.isNotEmpty && _calories > 0) {
      await DatabaseHelper.instance.insertFoodLog(_detectedFood, _calories);
      await loadFoodLogs();
      ScaffoldMessenger.of(this.context as BuildContext).showSnackBar(
        SnackBar(content: Text('Food logged successfully!')),
      );
    }
  }


  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/model.tflite');
      final labelsFile = await rootBundle.loadString('assets/models/labels.txt');
      _labels = labelsFile.split('\n');
      print("Model loaded successfully");
    } catch (e) {
      print("Error loading model: $e");
    }
  }

  Future<double> fetchNutritionalData(String foodItem) async {
    const String apiUrl = 'https://trackapi.nutritionix.com/v2/natural/nutrients';
    final Map<String, String> headers = {
      'accept': 'application/json',
      'x-app-id': 'a8259e1a',
      'x-app-key': 'f6e38658caea15ceb481b5e9e92a700e',
      'x-remote-user-id': '0',
      'Content-Type': 'application/json',
    };

    final Map<String, dynamic> payload = {
      'query': foodItem,
    };

    try {
      final http.Response response = await http.post(
        Uri.parse(apiUrl),
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        return data['foods'][0]['nf_calories'].toDouble();
      } else {
        print('API request failed with status code: ${response.statusCode}');
        return 0.0;
      }
    } catch (e) {
      print('Error fetching nutritional data: $e');
      return 0.0;
    }
  }

  Future<void> pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
        _isLoading = true;
      });

      await runModelOnImage(_selectedImage!);

      setState(() {
        _isLoading = false;
      });
    } else {
      print("No image selected.");
    }
  }

  Future<void> runModelOnImage(File image) async {
    if (_interpreter == null) {
      print("Interpreter is not initialized");
      return;
    }

    try {
      // Load and preprocess the image
      final imageData = img.decodeImage(await image.readAsBytes())!;
      final resizedImage = img.copyResize(imageData, width: 224, height: 224);

      // Convert image to normalized float32 tensor
      var input = List.filled(1 * 224 * 224 * 3, 0.0).reshape([1, 224, 224, 3]);

      for (var y = 0; y < 224; y++) {
        for (var x = 0; x < 224; x++) {
          final pixel = resizedImage.getPixel(x, y);
          input[0][y][x][0] = pixel.r.toDouble() / 255.0;
          input[0][y][x][1] = pixel.g.toDouble() / 255.0;
          input[0][y][x][2] = pixel.b.toDouble() / 255.0;
        }
      }

      var output = List.filled(1 * _labels!.length, 0.0).reshape([1, _labels!.length]);

      _interpreter!.run(input, output);

      var maxScore = 0.0;
      var maxIndex = 0;
      for (var i = 0; i < output[0].length; i++) {
        if (output[0][i] > maxScore) {
          maxScore = output[0][i];
          maxIndex = i;
        }
      }

      final detectedFood = _labels![maxIndex];
      final calories = await fetchNutritionalData(detectedFood);

      setState(() {
        _detectedFood = detectedFood;
        _calories = calories;
      });
    } catch (e) {
      print("Error running model: $e");
      setState(() {
        _detectedFood = "Error";
        _calories = 0.0;
      });
    }
  }

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Calorie Tracker'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Text(
                'Track Your Calories',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 20),
              _isLoading
                  ? Center(child: CircularProgressIndicator())
                  : _selectedImage == null
                  ? Text(
                'No image selected',
                style: TextStyle(fontSize: 16),
              )
                  : Image.file(
                _selectedImage!,
                height: 200,
              ),
              SizedBox(height: 20),
              if (!_isLoading && _detectedFood.isNotEmpty) ...[
                Text(
                  'Detected Food: $_detectedFood',
                  style: TextStyle(fontSize: 18),
                ),
                Text(
                  'Calories: ${_calories.toStringAsFixed(2)} kcal',
                  style: TextStyle(fontSize: 18, color: Colors.green),
                ),
                SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: logFood,
                  icon: Icon(Icons.add),
                  label: Text('Log Food'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                ),
              ],
              SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => pickImage(ImageSource.camera),
                    icon: Icon(Icons.camera_alt),
                    label: Text('Take Photo'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                    ),
                  ),
                  SizedBox(width: 20),
                  ElevatedButton.icon(
                    onPressed: () => pickImage(ImageSource.gallery),
                    icon: Icon(Icons.photo_library),
                    label: Text('Pick from Gallery'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 30),
              Text(
                'Food Log History',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              ListView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: _foodLogs.length,
                itemBuilder: (context, index) {
                  final log = _foodLogs[index];
                  final dateTime = DateTime.parse(log['date_time']);
                  return Card(
                    child: ListTile(
                      title: Text(log['food_name']),
                      subtitle: Text(
                        '${log['calories'].toStringAsFixed(2)} kcal\n${dateTime.toString().substring(0, 16)}',
                      ),
                      leading: Icon(Icons.fastfood),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
