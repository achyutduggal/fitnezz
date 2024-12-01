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
      version: 1, // Increment version if schema changes
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
        CREATE TABLE food_logs(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          food_name TEXT NOT NULL,
          calories REAL NOT NULL,
          date_time TEXT NOT NULL,
          sugar REAL DEFAULT 0.0,
          quantity INTEGER DEFAULT 1
        )
      ''');
  }

  Future<int> insertFoodLog(String foodName, double calories,
      {double sugar = 0.0, int quantity = 1}) async {
    final db = await database;
    final data = {
      'food_name': foodName,
      'calories': calories,
      'date_time': DateTime.now().toIso8601String(),
      'sugar': sugar,
      'quantity': quantity,
    };
    return await db.insert('food_logs', data);
  }

  Future<List<Map<String, dynamic>>> getFoodLogs() async {
    final db = await database;
    return await db.query('food_logs', orderBy: 'date_time DESC');
  }

  // Add a method to clear food logs
  Future<void> clearFoodLogs() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('food_logs');
  }
}

class CalorieTrackerScreen extends StatefulWidget {
  @override
  _CalorieTrackerScreenState createState() => _CalorieTrackerScreenState();
}

class _CalorieTrackerScreenState extends State<CalorieTrackerScreen> {
  File? _selectedImage;
  String _detectedFood = '';
  double _caloriesPerUnit = 0.0;
  double _sugarPerUnit = 0.0;
  double _totalCalories = 0.0;
  double _totalSugar = 0.0;
  bool _isLoading = false;
  bool _isHighSugar = false;
  Interpreter? _interpreter;
  List<String>? _labels;
  List<Map<String, dynamic>> _foodLogs = [];
  int _quantity = 1;
  double _dailyTotalSugar = 0.0;

  // List of high-sugar fruits
  Set<String> highSugarFruits = {
    'Apple',
    'Braeburn',
    'Crimson Snow',
    'Golden',
    'Granny Smith',
    'Pink Lady',
    'Red Delicious',
    'Banana',
    'Banana Lady Finger',
    'Banana Red',
    'Cherries',
    'Date',
    'Fig',
    'Grape',
    'Blue Grape',
    'Pink Grape',
    'White Grape',
    'Kaki',
    'Persimmon',
    'Lychee',
    'Mango',
    'Mango Red',
    'Mangostan',
    'Mangosteen',
    'Passion Fruit',
    'Granadilla',
    'Maracuja',
    'Pear',
    'Pear 2',
    'Peach',
    'Peach 2',
    'Peach Flat',
    'Nectarine',
    'Nectarine Flat',
    'Pineapple',
    'Pineapple Mini',
    'Plum',
    'Pomegranate',
    'Rambutan',
  };

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
    double totalSugar =
    logs.fold(0.0, (sum, log) => sum + (log['sugar'] ?? 0.0));
    setState(() {
      _foodLogs = logs;
      _dailyTotalSugar = totalSugar;
    });
  }

  Future<void> logFood() async {
    if (_detectedFood.isNotEmpty && _totalCalories > 0) {
      await DatabaseHelper.instance.insertFoodLog(
        _detectedFood,
        _totalCalories,
        sugar: _totalSugar,
        quantity: _quantity,
      );
      await loadFoodLogs();
    }
  }

  Future<void> clearFoodLogs() async {
    if (_foodLogs.isNotEmpty) {
      await DatabaseHelper.instance.clearFoodLogs();
      await loadFoodLogs();
      _dailyTotalSugar = 0;
    }
  }

  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/model.tflite');
      final labelsFile =
      await rootBundle.loadString('assets/models/labels.txt');
      _labels = labelsFile.split('\n');
      print("Model loaded successfully");
    } catch (e) {
      print("Error loading model: $e");
    }
  }

  Future<Map<String, double>> fetchNutritionalData(String foodItem) async {
    const String apiUrl =
        'https://trackapi.nutritionix.com/v2/natural/nutrients';
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
        double calories = data['foods'][0]['nf_calories'].toDouble();
        double sugars = data['foods'][0]['nf_sugars'].toDouble();
        return {'calories': calories, 'sugars': sugars};
      } else {
        print('API request failed with status code: ${response.statusCode}');
        return {'calories': 0.0, 'sugars': 0.0};
      }
    } catch (e) {
      print('Error fetching nutritional data: $e');
      return {'calories': 0.0, 'sugars': 0.0};
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

      var output =
      List.filled(1 * _labels!.length, 0.0).reshape([1, _labels!.length]);

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
      final nutritionData = await fetchNutritionalData(detectedFood);
      final calories = nutritionData['calories']!;
      final sugars = nutritionData['sugars']!;

      bool isHighSugar = highSugarFruits.contains(detectedFood);

      setState(() {
        _detectedFood = detectedFood;
        _caloriesPerUnit = calories;
        _sugarPerUnit = sugars;
        _isHighSugar = isHighSugar;
        _quantity = 1; // Reset quantity to 1
        calculateTotals();
      });
    } catch (e) {
      print("Error running model: $e");
      setState(() {
        _detectedFood = "Error";
        _caloriesPerUnit = 0.0;
        _sugarPerUnit = 0.0;
      });
    }
  }

  void calculateTotals() {
    _totalCalories = _caloriesPerUnit * _quantity;
    _totalSugar = _sugarPerUnit * _quantity;
  }

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }

  // Widget to select quantity
  Widget quantitySelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Quantity:',
          style: TextStyle(fontSize: 18),
        ),
        SizedBox(width: 10),
        DropdownButton<int>(
          value: _quantity,
          items: List.generate(20, (index) => index + 1)
              .map((value) => DropdownMenuItem<int>(
            value: value,
            child: Text(value.toString()),
          ))
              .toList(),
          onChanged: (newValue) {
            setState(() {
              _quantity = newValue!;
              calculateTotals();
            });
          },
        ),
      ],
    );
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
                SizedBox(height: 10),
                quantitySelector(),
                SizedBox(height: 10),
                Text(
                  'Calories per unit: ${_caloriesPerUnit.toStringAsFixed(2)} kcal',
                  style: TextStyle(fontSize: 16),
                ),
                Text(
                  'Sugar per unit: ${_sugarPerUnit.toStringAsFixed(2)} g',
                  style: TextStyle(fontSize: 16),
                ),
                SizedBox(height: 10),
                Text(
                  'Total Calories: ${_totalCalories.toStringAsFixed(2)} kcal',
                  style: TextStyle(fontSize: 18, color: Colors.green),
                ),
                Text(
                  'Total Sugar: ${_totalSugar.toStringAsFixed(2)} g',
                  style: TextStyle(fontSize: 18, color: Colors.red),
                ),
                if (_isHighSugar)
                  Text(
                    'Warning: This food has high sugar content!',
                    style: TextStyle(fontSize: 18, color: Colors.red),
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
                      padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                  ),
                  SizedBox(width: 20),
                  ElevatedButton.icon(
                    onPressed: () => pickImage(ImageSource.gallery),
                    icon: Icon(Icons.photo_library),
                    label: Text('Pick from Gallery'),
                    style: ElevatedButton.styleFrom(
                      padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 30),
              SugarCounter(
                totalSugar: _dailyTotalSugar,
                sugarThreshold: 30.0,
                showAlertCallback: () {
                  showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: Text('High Sugar Intake Alert!'),
                        content: Text(
                          'You have consumed ${_dailyTotalSugar.toStringAsFixed(2)} g of sugar, which exceeds the recommended daily limit of 30 g.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                            },
                            child: Text('OK'),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Food Log History',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_forever, color: Colors.red),
                    onPressed: clearFoodLogs,
                  ),
                ],
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
                      title: Text('${log['food_name']}'),
                      subtitle: Text(
                        '${log['calories'].toStringAsFixed(2)} kcal\nSugar: ${log['sugar']?.toStringAsFixed(2) ?? '0.00'} g\n${dateTime.toString().substring(0, 16)}',
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

// Separate widget to count and display total sugar
class SugarCounter extends StatelessWidget {
  final double totalSugar;
  final double sugarThreshold;
  final VoidCallback showAlertCallback;

  SugarCounter({
    required this.totalSugar,
    required this.sugarThreshold,
    required this.showAlertCallback,
  });

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (totalSugar > sugarThreshold) {
        showAlertCallback();
      }
    });

    return Column(
      children: [
        Text(
          'Total Sugar Consumed: ${totalSugar.toStringAsFixed(2)} g',
          style: TextStyle(
              fontSize: 18, color: Colors.red, fontWeight: FontWeight.bold),
        ),
        if (totalSugar > sugarThreshold)
          Text(
            'You have exceeded the recommended sugar intake!',
            style: TextStyle(fontSize: 18, color: Colors.red),
          ),
      ],
    );
  }
}
