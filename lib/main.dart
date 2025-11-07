import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:permission_handler/permission_handler.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

// ----------------------
// Firestore Models
// ----------------------
class Task {
  final String id;
  String title;
  String description;
  DateTime dueDate;
  String category;
  bool isCompleted;
  String priority;

  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.dueDate,
    required this.category,
    this.isCompleted = false,
    this.priority = "Medium",
  });

  factory Task.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map;
    return Task(
      id: doc.id,
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      dueDate: (data['dueDate'] as Timestamp).toDate(),
      category: data['category'] ?? '',
      isCompleted: data['isCompleted'] ?? false,
      priority: data['priority'] ?? 'Medium',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      'description': description,
      'dueDate': dueDate,
      'category': category,
      'isCompleted': isCompleted,
      'priority': priority,
    };
  }
}

// ----------------------
// Notification Service
// ----------------------
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
  FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // Add iOS/macOS settings to request notification permissions
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Pass both settings to the constructor
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _notificationsPlugin.initialize(settings);
    tz.initializeTimeZones();
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  static Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime dueDate,
  }) async {
    final reminderTime = dueDate.subtract(const Duration(hours: 1));
    if (reminderTime.isAfter(DateTime.now())) {
      await _notificationsPlugin.zonedSchedule(
        id,
        "Upcoming Task",
        "${title} is due in 1 hour!",
        tz.TZDateTime.from(reminderTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'task_manager_channel',
            'Task Notifications',
            channelDescription: 'Reminders for tasks',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidAllowWhileIdle: true,
        uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
    final expiredTime = dueDate;
    if (expiredTime.isAfter(DateTime.now())) {
      await _notificationsPlugin.zonedSchedule(
        id + 1,
        "Task Expired",
        "${title} has expired.",
        tz.TZDateTime.from(expiredTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'task_manager_channel',
            'Task Notifications',
            channelDescription: 'Reminders for tasks',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidAllowWhileIdle: true,
        uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  static Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
    await _notificationsPlugin.cancel(id + 1);
  }

  static Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }
}

// ----------------------
// Google Sign-In + Calendar
// ----------------------
final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: [
    'email',
    'https://www.googleapis.com/auth/calendar',
  ],
);

Future<http.Client> _getAuthClient() async {
  final account =
      await _googleSignIn.signInSilently() ?? await _googleSignIn.signIn();
  if (account == null) throw Exception("Google Sign-In failed");

  final headers = await account.authHeaders;
  return _GoogleAuthClient(headers);
}

class _GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  _GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

Future<void> addTaskToGoogleCalendar(Task task) async {
  try {
    final client = await _getAuthClient();
    final calendarApi = calendar.CalendarApi(client);

    final event = calendar.Event(
      summary: task.title,
      description: task.description,
      start: calendar.EventDateTime(
        dateTime: task.dueDate.subtract(const Duration(hours: 1)),
        timeZone: "Asia/Kolkata",
      ),
      end: calendar.EventDateTime(
        dateTime: task.dueDate,
        timeZone: "Asia/Kolkata",
      ),
    );

    await calendarApi.events.insert(event, "primary");
    print("✅ Task '${task.title}' synced to Google Calendar");
  } catch (e) {
    print("❌ Failed to sync with Google Calendar: $e");
  }
}

// ----------------------
// Main App
// ----------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await NotificationService.init();

  runApp(const TaskManagerRoot());
}

class TaskManagerRoot extends StatefulWidget {
  const TaskManagerRoot({Key? key}) : super(key: key);

  @override
  State<TaskManagerRoot> createState() => _TaskManagerRootState();
}

class _TaskManagerRootState extends State<TaskManagerRoot> {
  bool _isDarkTheme = false;

  void _toggleTheme() {
    setState(() {
      _isDarkTheme = !_isDarkTheme;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Task Manager',
      debugShowCheckedModeBanner: false,
      themeMode: _isDarkTheme ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: Colors.grey[100],
        cardTheme: const CardThemeData(
          elevation: 4,
          margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: Colors.black,
        cardTheme: const CardThemeData(
          elevation: 4,
          margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
      ),
      home: AuthScreen(onToggleTheme: _toggleTheme),
    );
  }
}

// ----------------------
// Authentication Screen
// ----------------------
class AuthScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const AuthScreen({Key? key, required this.onToggleTheme}) : super(key: key);

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool isLogin = true;

  Future<void> checkAndCreateUserDocument(User firebaseUser) async {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(firebaseUser.uid);
    final docSnapshot = await userDoc.get();

    if (!docSnapshot.exists) {
      await userDoc.set({
        'email': firebaseUser.email,
        'created_at': FieldValue.serverTimestamp(),
      });
    }
  }

  void _authenticate() async {
    final auth = FirebaseAuth.instance;
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    try {
      if (isLogin) {
        final userCredential = await auth.signInWithEmailAndPassword(email: username, password: password);
        await checkAndCreateUserDocument(userCredential.user!);
      } else {
        final userCredential = await auth.createUserWithEmailAndPassword(email: username, password: password);
        await checkAndCreateUserDocument(userCredential.user!);
      }
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => TaskScreen(onToggleTheme: widget.onToggleTheme),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? "Authentication failed")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.task_alt,
                        size: 80, color: Theme.of(context).primaryColor),
                    const SizedBox(height: 16),
                    Text(
                      isLogin ? "Welcome Back" : "Create Account",
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: "Email",
                        prefixIcon: Icon(Icons.person),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || !value.contains('@')) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: "Password",
                        prefixIcon: Icon(Icons.lock),
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _authenticate,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(isLogin ? "Login" : "Sign Up"),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          isLogin = !isLogin;
                        });
                      },
                      child: Text(isLogin
                          ? "Don't have an account? Sign Up"
                          : "Already have an account? Login"),
                    ),
                    IconButton(
                      icon: const Icon(Icons.brightness_6),
                      onPressed: widget.onToggleTheme,
                      tooltip: "Toggle Theme",
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.login),
                      label: const Text("Login with Google"),
                      onPressed: () async {
                        try {
                          final googleUser = await _googleSignIn.signIn();
                          if (googleUser == null) return;
                          final googleAuth = await googleUser.authentication;
                          final credential = GoogleAuthProvider.credential(
                            accessToken: googleAuth.accessToken,
                            idToken: googleAuth.idToken,
                          );
                          final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
                          await checkAndCreateUserDocument(userCredential.user!);

                          if (mounted) {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      TaskScreen(onToggleTheme: widget.onToggleTheme)),
                            );
                          }
                        } on FirebaseAuthException catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Google Sign-In failed: ${e.message}")),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Google Sign-In failed: $e")),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------
// Task Screen
// ----------------------
class TaskScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const TaskScreen({Key? key, required this.onToggleTheme}) : super(key: key);

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  final tasksCollection = FirebaseFirestore.instance.collection('tasks');
  String filterPriority = "All";
  String filterCategory = "All";

  void _openProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ProfileScreen(onToggleTheme: widget.onToggleTheme)),
    );
  }

  Color _priorityColor(String priority) {
    switch (priority) {
      case "High":
        return Colors.red;
      case "Low":
        return Colors.green;
      default:
        return Colors.orange;
    }
  }

  Color _categoryColor(String category) {
    switch (category) {
      case "Work":
        return Colors.blue;
      case "Home":
        return Colors.purple;
      case "Personal":
        return Colors.pink;
      case "Other":
        return Colors.grey;
      default:
        return Colors.teal;
    }
  }

  void _showTaskDialog({Task? task}) {
    final titleController = TextEditingController(text: task?.title ?? "");
    final descController = TextEditingController(text: task?.description ?? "");
    DateTime? selectedDate = task?.dueDate;
    String priority = task?.priority ?? "Medium";
    String category = task?.category ?? "Work";

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(task == null ? "Add Task" : "Edit Task"),
              content: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(controller: titleController, decoration: const InputDecoration(labelText: "Title")),
                    TextField(controller: descController, decoration: const InputDecoration(labelText: "Description")),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: category,
                      decoration: const InputDecoration(labelText: "Category"),
                      items: ["Work", "Home", "Personal", "Other"]
                          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) category = val;
                      },
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: () async {
                        final pickedDate = await showDatePicker(
                          context: context,
                          initialDate: selectedDate ?? DateTime.now(),
                          firstDate: DateTime.now(),
                          lastDate: DateTime(2100),
                        );
                        if (pickedDate != null) {
                          final pickedTime = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(
                                selectedDate ?? DateTime.now()),
                          );
                          if (pickedTime != null) {
                            setState(() {
                              selectedDate = DateTime(
                                pickedDate.year,
                                pickedDate.month,
                                pickedDate.day,
                                pickedTime.hour,
                                pickedTime.minute,
                              );
                            });
                          }
                        }
                      },
                      child: Text(selectedDate != null ? "Due: ${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year} ${selectedDate!.hour}:${selectedDate!.minute.toString().padLeft(2, '0')}" : "Pick Due Date & Time"),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: priority,
                      decoration: const InputDecoration(labelText: "Priority"),
                      items: ["Low", "Medium", "High"]
                          .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) priority = val;
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () async {
                    if (titleController.text.isNotEmpty && selectedDate != null) {
                      if (task == null) {
                        final newTaskData = {
                          'title': titleController.text,
                          'description': descController.text,
                          'dueDate': selectedDate,
                          'category': category,
                          'priority': priority,
                          'isCompleted': false,
                          'userId': FirebaseAuth.instance.currentUser!.uid,
                        };
                        final docRef = await tasksCollection.add(newTaskData);
                        final newTask = Task(
                          id: docRef.id,
                          title: titleController.text,
                          description: descController.text,
                          dueDate: selectedDate!,
                          category: category,
                          priority: priority,
                        );
                        NotificationService.scheduleNotification(
                          id: newTask.id.hashCode,
                          title: newTask.title,
                          body: "You have an upcoming task!",
                          dueDate: newTask.dueDate,
                        );
                        addTaskToGoogleCalendar(newTask);
                      } else {
                        await tasksCollection.doc(task.id).update({
                          'title': titleController.text,
                          'description': descController.text,
                          'dueDate': selectedDate,
                          'category': category,
                          'priority': priority,
                        });
                        task.title = titleController.text;
                        task.description = descController.text;
                        task.dueDate = selectedDate!;
                        task.category = category;
                        task.priority = priority;
                        NotificationService.scheduleNotification(
                          id: task.id.hashCode,
                          title: task.title,
                          body: "Task updated!",
                          dueDate: task.dueDate,
                        );
                        addTaskToGoogleCalendar(task);
                      }
                      Navigator.pop(dialogContext);
                    }
                  },
                  child: Text(task == null ? "Add" : "Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final username = currentUser?.email ?? 'Guest';
    final currentUserId = currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Task Manager"),
        actions: [
          IconButton(icon: const Icon(Icons.brightness_6), onPressed: widget.onToggleTheme),
          IconButton(icon: const Icon(Icons.person), onPressed: _openProfile),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
              child: Text('Hello, $username', style: const TextStyle(color: Colors.white, fontSize: 24)),
            ),
            ListTile(
              title: const Text('Filter by Priority'),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  setState(() => filterPriority = value);
                  Navigator.pop(context);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: "All", child: Text("All Priorities")),
                  PopupMenuItem(value: "High", child: Text("High Priority")),
                  PopupMenuItem(value: "Medium", child: Text("Medium Priority")),
                  PopupMenuItem(value: "Low", child: Text("Low Priority")),
                ],
              ),
            ),
            ListTile(
              title: const Text('Filter by Category'),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  setState(() => filterCategory = value);
                  Navigator.pop(context);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: "All", child: Text("All Categories")),
                  PopupMenuItem(value: "Work", child: Text("Work")),
                  PopupMenuItem(value: "Home", child: Text("Home")),
                  PopupMenuItem(value: "Personal", child: Text("Personal")),
                  PopupMenuItem(value: "Other", child: Text("Other")),
                ],
              ),
            ),
          ],
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: tasksCollection.where('userId', isEqualTo: currentUserId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text("Error fetching tasks"));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No tasks added yet!"));
          }

          var tasks = snapshot.data!.docs.map((doc) => Task.fromFirestore(doc)).toList();
          tasks.sort((a, b) => a.dueDate.compareTo(b.dueDate));

          if (filterPriority != "All") {
            tasks = tasks.where((t) => t.priority == filterPriority).toList();
          }
          if (filterCategory != "All") {
            tasks = tasks.where((t) => t.category == filterCategory).toList();
          }

          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (_, i) {
              final task = tasks[i];
              return Card(
                child: InkWell(
                  onTap: () {
                    tasksCollection.doc(task.id).update({'isCompleted': !task.isCompleted});
                  },
                  onLongPress: () => _showTaskDialog(task: task),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _categoryColor(task.category),
                      child: Icon(
                        task.isCompleted ? Icons.check : Icons.task,
                        color: Colors.white,
                      ),
                    ),
                    title: Text(
                      task.title,
                      style: TextStyle(
                        decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text("Due: ${task.dueDate.day}/${task.dueDate.month}/${task.dueDate.year} ${task.dueDate.hour}:${task.dueDate.minute.toString().padLeft(2, '0')}"),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        NotificationService.cancelNotification(task.id.hashCode);
                        tasksCollection.doc(task.id).delete();
                      },
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(onPressed: () => _showTaskDialog(), child: const Icon(Icons.add)),
    );
  }
}

// ----------------------
// Profile Screen
// ----------------------
class ProfileScreen extends StatelessWidget {
  final VoidCallback onToggleTheme;
  const ProfileScreen({Key? key, required this.onToggleTheme}) : super(key: key);

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirm Logout"),
        content: const Text("Are you sure you want to log out?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              await _googleSignIn.signOut();
              if (ctx.mounted) {
                Navigator.of(ctx).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => AuthScreen(onToggleTheme: onToggleTheme)),
                      (route) => false,
                );
              }
            },
            child: const Text("Log Out"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final tasksCollection = FirebaseFirestore.instance.collection('tasks');
    final currentUserId = currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Profile"),
        actions: [IconButton(icon: const Icon(Icons.brightness_6), onPressed: onToggleTheme)],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: StreamBuilder<QuerySnapshot>(
                stream: tasksCollection.where('userId', isEqualTo: currentUserId).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const CircularProgressIndicator();
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return const Text("Error loading data");
                  }

                  final tasks = snapshot.data!.docs;
                  final totalTasks = tasks.length;
                  final completedTasks = tasks.where((doc) => doc['isCompleted'] == true).length;
                  final pendingTasks = totalTasks - completedTasks;
                  final completionPercentage = totalTasks > 0 ? completedTasks / totalTasks : 0.0;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (currentUser != null) ...[
                        CircleAvatar(radius: 40, child: Text(currentUser.email?[0].toUpperCase() ?? 'G', style: const TextStyle(fontSize: 30))),
                        const SizedBox(height: 20),
                        Text(currentUser.email ?? 'Guest', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 30),
                      ],
                      SizedBox(
                        height: 120,
                        width: 120,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CircularProgressIndicator(
                              value: completionPercentage,
                              strokeWidth: 8,
                              backgroundColor: Theme.of(context).cardColor,
                              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                            ),
                            Center(
                              child: Text(
                                '${(completionPercentage * 100).toInt()}%',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatCard("Total", totalTasks, Colors.blue),
                          _buildStatCard("Completed", completedTasks, Colors.green),
                          _buildStatCard("Pending", pendingTasks, Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 30),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text("Log Out"),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _confirmLogout(context),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(title),
      ],
    );
  }
}
