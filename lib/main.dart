import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String appsScriptUrl =
    "https://script.google.com/macros/s/AKfycbzA3EorTl2Ag9EzZ-t4joKNa1NzJfeIxil6pggNt0yI_TEkXfOm6-QrdfeKkcEldyBI6A/exec";

const String offlineQueueKey = "transport_bill_offline_queue";

void main() {
  runApp(const TransportBillApp());
}

class TransportBillApp extends StatelessWidget {
  const TransportBillApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "TRANSPORT BILL",
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const TransportBillScreen(),
    );
  }
}

enum SaveResult {
  saved,
  duplicate,
  rejected,
  offline,
  unknown,
}

class TransportBillScreen extends StatefulWidget {
  const TransportBillScreen({super.key});

  @override
  State<TransportBillScreen> createState() => _TransportBillScreenState();
}

class _TransportBillScreenState extends State<TransportBillScreen> {
  final TextEditingController empCodeController = TextEditingController();
  final TextEditingController billNoController = TextEditingController();
  final TextEditingController amountController = TextEditingController();
  final TextEditingController remarksController = TextEditingController();

  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;
  Timer? syncTimer;

  bool isSearching = false;
  bool isSaving = false;
  bool isSyncing = false;

  String driverName = "";
  String company = "";
  String mobile = "";

  double totalAdvance = 0;
  double totalBill = 0;
  double remainingBalance = 0;

  String transactionType = "ADVANCE";

  @override
  void initState() {
    super.initState();

    connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (_hasInternet(results)) {
        _syncOfflineQueue();
      }
    });

    syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        _syncOfflineQueue();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncOfflineQueue();
    });
  }

  @override
  void dispose() {
    connectivitySubscription?.cancel();
    syncTimer?.cancel();
    empCodeController.dispose();
    billNoController.dispose();
    amountController.dispose();
    remarksController.dispose();
    super.dispose();
  }

  bool _hasInternet(List<ConnectivityResult> results) {
    return results.contains(ConnectivityResult.mobile) ||
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet) ||
        results.contains(ConnectivityResult.vpn);
  }

  Future<bool> hasInternet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!_hasInternet(results)) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  double toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(
          value.toString().replaceAll(",", "").trim(),
        ) ??
        0;
  }

  String createSyncId() {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch.remainder(1000000);
    return "TX_${now}_$random";
  }

  Map<String, dynamic>? _safeMapDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  Future<http.Response> getWithRetry(
    Uri uri, {
    int timeoutSeconds = 20,
  }) async {
    return await http.get(
      uri,
      headers: {
        "Accept": "application/json",
        "Cache-Control": "no-cache",
      },
    ).timeout(
      Duration(seconds: timeoutSeconds),
    );
  }

  Future<http.Response> postRequest(
    Uri uri,
    String body, {
    int timeoutSeconds = 20,
  }) async {
    return await http
        .post(
          uri,
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          body: body,
        )
        .timeout(
          Duration(seconds: timeoutSeconds),
        );
  }

  Future<void> searchDriver() async {
    final empCode = empCodeController.text.trim();
    if (empCode.isEmpty) {
      showMessage("Please enter Emp Code");
      return;
    }

    if (isSearching) return;

    FocusScope.of(context).unfocus();

    setState(() {
      isSearching = true;
      driverName = "";
      company = "";
      mobile = "";
      totalAdvance = 0;
      totalBill = 0;
      remainingBalance = 0;
      billNoController.clear();
      amountController.clear();
      remarksController.clear();
      transactionType = "ADVANCE";
    });

    try {
      final uri = Uri.parse(
        "$appsScriptUrl?action=getDriver&empCode=${Uri.encodeComponent(empCode)}",
      );

      final response = await getWithRetry(
        uri,
        timeoutSeconds: 20,
      );

      if (response.statusCode != 200) {
        throw Exception("Server error ${response.statusCode}");
      }

      final body = _safeMapDecode(response.body);
      if (body == null) {
        throw Exception("Invalid JSON response from server");
      }

      if (body["success"] == true) {
        final driverRaw = body["driver"];
        final driver =
            driverRaw is Map ? Map<String, dynamic>.from(driverRaw) : {};

        if (!mounted) return;

        setState(() {
          driverName = driver["driverName"]?.toString() ?? "";
          company = driver["company"]?.toString() ?? "";
          mobile = driver["mobile"]?.toString() ?? "";
          totalAdvance = toDouble(driver["totalAdvance"]);
          totalBill = toDouble(driver["totalBill"]);
          remainingBalance = toDouble(driver["remainingBalance"]);
        });
      } else {
        if (!mounted) return;

        setState(() {
          driverName = "";
          company = "";
          mobile = "";
          totalAdvance = 0;
          totalBill = 0;
          remainingBalance = 0;
        });

        showMessage(
          body["message"]?.toString() ?? "Employee not found",
        );
      }
    } on TimeoutException {
      if (mounted) {
        showMessage(
          "Google Sheet connection is slow. Please try again.",
        );
      }
    } catch (e) {
      if (mounted) {
        showMessage(
          "Unable to connect to Google Sheet.",
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isSearching = false;
        });
      }
    }
  }

  Future<void> openScanner() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QRScannerPage(),
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      empCodeController.text = result.trim();
      await searchDriver();
    }
  }

  Future<void> saveTransaction() async {
    if (isSaving) return;

    final empCode = empCodeController.text.trim();
    final amountText = amountController.text.trim();
    final billNo = billNoController.text.trim();
    final remarks = remarksController.text.trim();

    if (empCode.isEmpty) {
      showMessage("Please enter Emp Code");
      return;
    }

    if (driverName.isEmpty) {
      showMessage("Please search driver first");
      return;
    }

    if (transactionType == "BILL" && billNo.isEmpty) {
      showMessage("Bill No is required");
      return;
    }

    final amount = double.tryParse(
      amountText.replaceAll(",", ""),
    );

    if (amount == null || amount <= 0) {
      showMessage("Please enter valid amount");
      return;
    }

    setState(() {
      isSaving = true;
    });

    final syncId = createSyncId();

    final transaction = <String, dynamic>{
      "action": "addTransaction",
      "empCode": empCode,
      "type": transactionType,
      "billNo": transactionType == "BILL" ? billNo : "",
      "amount": amount,
      "remarks": remarks,
      "syncId": syncId,
    };

    try {
      final internet = await hasInternet();

      if (!internet) {
        await saveOfflineTransaction(transaction);
        if (mounted) {
          showMessage("OFFLINE SAVED");
          clearTransactionFields();
        }
        return;
      }

      final result = await sendTransactionToGoogle(
        transaction,
      );

      if (!mounted) return;

      if (result == SaveResult.saved) {
        showMessage("SAVED IN GOOGLE SHEET");
        clearTransactionFields();
        await searchDriver();
      } else if (result == SaveResult.duplicate) {
        showMessage("Duplicate transaction");
      } else if (result == SaveResult.offline) {
        await saveOfflineTransaction(transaction);
        showMessage("OFFLINE SAVED");
        clearTransactionFields();
      } else {
        showMessage(
          "Unable to save transaction",
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  Future<SaveResult> sendTransactionToGoogle(
    Map<String, dynamic> transaction,
  ) async {
    final syncId = transaction["syncId"]?.toString() ?? "";

    try {
      final response = await postRequest(
        Uri.parse(appsScriptUrl),
        jsonEncode(transaction),
        timeoutSeconds: 20,
      );

      if (response.statusCode != 200) {
        final found = await checkSyncIdOnServer(syncId);
        if (found) {
          return SaveResult.saved;
        }
        return SaveResult.unknown;
      }

      final body = _safeMapDecode(response.body);
      if (body != null) {
        if (body["success"] == true) {
          return SaveResult.saved;
        }
        if (body["duplicate"] == true) {
          return SaveResult.duplicate;
        }
        return SaveResult.rejected;
      }

      final found = await checkSyncIdOnServer(syncId);
      if (found) {
        return SaveResult.saved;
      }

      return SaveResult.unknown;
    } on TimeoutException {
      final found = await checkSyncIdOnServer(syncId);
      if (found) {
        return SaveResult.saved;
      }
      return SaveResult.offline;
    } catch (_) {
      final found = await checkSyncIdOnServer(syncId);
      if (found) {
        return SaveResult.saved;
      }
      return SaveResult.offline;
    }
  }

  Future<bool> checkSyncIdOnServer(String syncId) async {
    if (syncId.isEmpty) return false;

    try {
      final uri = Uri.parse(
        "$appsScriptUrl?action=checkTransaction&syncId=${Uri.encodeComponent(syncId)}",
      );

      final response = await http.get(
        uri,
        headers: {
          "Accept": "application/json",
          "Cache-Control": "no-cache",
        },
      ).timeout(
        const Duration(seconds: 12),
      );

      if (response.statusCode != 200) {
        return false;
      }

      final body = _safeMapDecode(response.body);
      if (body != null) {
        return body["success"] == true && body["found"] == true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(offlineQueueKey) ?? [];
    final result = <Map<String, dynamic>>[];

    for (final item in list) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map) {
          result.add(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }

    return result;
  }

  Future<void> saveOfflineTransaction(
    Map<String, dynamic> transaction,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(offlineQueueKey) ?? [];
    final syncId = transaction["syncId"]?.toString() ?? "";

    bool exists = false;
    for (final item in list) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map && decoded["syncId"]?.toString() == syncId) {
          exists = true;
          break;
        }
      } catch (_) {}
    }

    if (!exists) {
      list.add(jsonEncode(transaction));
      await prefs.setStringList(
        offlineQueueKey,
        list,
      );
    }
  }

  Future<void> _syncOfflineQueue() async {
    if (isSyncing) return;

    final internet = await hasInternet();
    if (!internet) return;

    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(offlineQueueKey) ?? [];
    if (list.isEmpty) return;

    isSyncing = true;

    try {
      final remaining = <String>[];

      for (final item in list) {
        try {
          final decoded = jsonDecode(item);
          if (decoded is! Map) {
            continue;
          }

          final transaction = Map<String, dynamic>.from(decoded);
          final syncId = transaction["syncId"]?.toString() ?? "";
          if (syncId.isEmpty) {
            continue;
          }

          final alreadySaved = await checkSyncIdOnServer(syncId);
          if (alreadySaved) {
            continue;
          }

          final result = await sendOfflineTransactionOnce(
            transaction,
          );

          if (result == SaveResult.saved || result == SaveResult.duplicate) {
            continue;
          }

          remaining.add(
            jsonEncode(transaction),
          );
        } catch (_) {
          remaining.add(item);
        }
      }

      await prefs.setStringList(
        offlineQueueKey,
        remaining,
      );
    } finally {
      isSyncing = false;
    }
  }

  Future<SaveResult> sendOfflineTransactionOnce(
    Map<String, dynamic> transaction,
  ) async {
    final syncId = transaction["syncId"]?.toString() ?? "";

    try {
      final response = await postRequest(
        Uri.parse(appsScriptUrl),
        jsonEncode(transaction),
        timeoutSeconds: 20,
      );

      if (response.statusCode != 200) {
        final found = await checkSyncIdOnServer(syncId);
        return found ? SaveResult.saved : SaveResult.unknown;
      }

      final body = _safeMapDecode(response.body);
      if (body != null) {
        if (body["success"] == true) {
          return SaveResult.saved;
        }
        if (body["duplicate"] == true) {
          return SaveResult.duplicate;
        }
      }

      final found = await checkSyncIdOnServer(syncId);
      return found ? SaveResult.saved : SaveResult.unknown;
    } on TimeoutException {
      final found = await checkSyncIdOnServer(syncId);
      return found ? SaveResult.saved : SaveResult.unknown;
    } catch (_) {
      final found = await checkSyncIdOnServer(syncId);
      return found ? SaveResult.saved : SaveResult.unknown;
    }
  }

  void clearTransactionFields() {
    if (!mounted) return;

    setState(() {
      transactionType = "ADVANCE";
      billNoController.clear();
      amountController.clear();
      remarksController.clear();
    });
  }

  Future<void> refreshDriver() async {
    if (empCodeController.text.trim().isEmpty) return;
    await searchDriver();
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  String formatMoney(double value) {
    return NumberFormat("#,##0.00").format(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "TRANSPORT BILL",
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: refreshDriver,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: empCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: "Emp Code",
                        border: const OutlineInputBorder(),
                        suffixIcon: isSearching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                      ),
                      onSubmitted: (_) {
                        searchDriver();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: isSearching ? null : searchDriver,
                      child: const Text("SEARCH"),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    width: 56,
                    child: ElevatedButton(
                      onPressed: isSearching ? null : openScanner,
                      child: const Icon(
                        Icons.qr_code_scanner,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "DRIVER INFORMATION",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      infoRow(
                        "Emp Code",
                        empCodeController.text,
                      ),
                      infoRow(
                        "Driver Name",
                        driverName,
                      ),
                      infoRow(
                        "Company",
                        company,
                      ),
                      infoRow(
                        "Mobile No.",
                        mobile,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "BALANCE",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      infoRow(
                        "Remaining Balance",
                        formatMoney(
                          remainingBalance,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "TRANSACTION",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: transactionType,
                        decoration: const InputDecoration(
                          labelText: "Transaction Type",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: "ADVANCE",
                            child: Text("ADVANCE"),
                          ),
                          DropdownMenuItem(
                            value: "BILL",
                            child: Text("BILL"),
                          ),
                        ],
                        onChanged: isSaving
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  transactionType = value;
                                  if (value == "ADVANCE") {
                                    billNoController.clear();
                                  }
                                });
                              },
                      ),
                      const SizedBox(height: 12),
                      if (transactionType == "BILL")
                        TextField(
                          controller: billNoController,
                          decoration: const InputDecoration(
                            labelText: "Bill No",
                            border: OutlineInputBorder(),
                          ),
                        ),
                      if (transactionType == "BILL") const SizedBox(height: 12),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: "Amount",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: remarksController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: "Remarks",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: isSaving ? null : saveTransaction,
                          child: isSaving
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "SAVE TRANSACTION",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget infoRow(
    String title,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? "-" : value,
            ),
          ),
        ],
      ),
    );
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController controller = MobileScannerController();
  bool alreadyScanned = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void onDetect(BarcodeCapture capture) {
    if (alreadyScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        alreadyScanned = true;
        Navigator.pop(
          context,
          value.trim(),
        );
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SCAN QR"),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.flash_on,
            ),
            onPressed: () {
              controller.toggleTorch();
            },
          ),
          IconButton(
            icon: const Icon(
              Icons.cameraswitch,
            ),
            onPressed: () {
              controller.switchCamera();
            },
          ),
        ],
      ),
      body: MobileScanner(
        controller: controller,
        onDetect: onDetect,
      ),
    );
  }
}
