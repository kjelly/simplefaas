import "dart:async";
import "dart:io";
import "dart:convert";
import 'package:yaml/yaml.dart';
import 'package:hive/hive.dart';
import 'package:start/start.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:args/args.dart';

String getCID(Request request) {
  for (var i in request.cookies) {
    if (i.name == 'cid') {
      return i.value;
    }
  }
  return '';
}

void main(List<String> args) async {
  final log = Logger("main");
  var parser = new ArgParser();
  parser.addMultiOption('path',
      abbr: "p", help: 'The path which is allowed to write the files.');
  parser.addMultiOption('exec',
      abbr: "e", help: 'the binary which is allowed to execute.');
  parser.addOption('static',
      abbr: "s", help: 'static files', defaultsTo: 'static');
  parser.addOption('config', abbr: "c", help: 'config file', defaultsTo: '');
  parser.addOption('token', abbr: "t", help: 'token', defaultsTo: '');

  parser.addOption('port', defaultsTo: '3000');

  var argResults = parser.parse(args);
  var yamlMap = YamlMap();

  if (argResults['config'] != '') {
    var f = File(argResults['config']);
    yamlMap = loadYaml(f.readAsStringSync());
  }

  var configListString = Map<String, List<String>>();

  for (var i in ['path', 'exec']) {
    configListString[i] = argResults[i];
    for (var j in yamlMap[i]) {
      if (configListString[i] != null) {
        configListString[i]?.add(j);
      }
    }
  }
  print(configListString);

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((rec) {
    print('${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  var uuidGenerator = Uuid();
  var token = argResults['token'];

  final allowedProgram = argResults['exec'] as List<String>;
  final allowedPath = argResults['path'] as List<String>;
  final defaultPort = int.tryParse(argResults['port'] ?? '3000') ?? 3000;
  final timeOut = 15;

  start(
          host: '0.0.0.0',
          port: int.tryParse(argResults['port'] ?? defaultPort.toString()) ??
              defaultPort)
      .then((Server app) {
    var processResult = Map<String, Map<String, String>>();
    var runningProcess = [];

    bool checkRequestToken(Request request) {
      if(!request.isMime('application/json')){
        final v = request.header('Content-Type').toString();
        request.response.status(500).json({"error": 'Only support content-type application/json. Current value: $v}'});
        return false;
      }
      request.response.header('Access-Control-Allow-Origin', 'http://192.168.11.26:1111');
      if (getCID(request) == '') {
        request.response.cookie('cid', uuidGenerator.v4());
      }
      var headerToken = request.header('token') ?? List<String>();
      if (token != '' && !headerToken.contains(token)) {
        request.response.status(401).json({"error": 'Not allow to access.'});
        return false;
      }
      return true;
    }

    app.static(argResults['static']);

    app.post('/runsync/').where(checkRequestToken).listen((request) async {
      bool responseClosed = false;
      request.payload().then((m) {
        final program = m['program'] ?? "";
        final programArgs = m['args']?.cast<String>() ?? List<String>();
        if (program == "") {
          request.response.status(400).json({"error": 'no program to run.'});
          return;
        }
        var programEnvironment = Map<String, String>()
          ..addAll(Platform.environment);
        programEnvironment['cid'] = getCID(request);
        if (!allowedProgram.contains(program)) {
          request.response
              .status(403)
              .json({"error": 'not allow to run the program.'});
          return;
        }
        Process.run(program, programArgs, environment: programEnvironment)
            .then((pr) {
          var m = {
            'stdout': pr.stdout,
            'stderr': pr.stderr,
            'exitcode': pr.exitCode
          };
          if (!responseClosed) {
            responseClosed = true;
            request.response.json(m);
          }
        });
        Future.delayed(Duration(seconds: timeOut), () {
          if (!responseClosed) {
            responseClosed = true;
            request.response.json({'error': 'timeout'});
          }
        });
      });
    });

    app.post('/run/').where(checkRequestToken).listen((request) async {
      bool responseClosed = false;
      request.payload().then((m) {
        final program = m['program'] ?? "";
        final programArgs = m['args']?.cast<String>() ?? List<String>();
        if (program == "") {
          request.response.status(400).json({"error": 'no program to run.'});
          return;
        }
        var programEnvironment = Map<String, String>()
          ..addAll(Platform.environment);
        programEnvironment['cid'] = getCID(request);
        if (!allowedProgram.contains(program)) {
          request.response
              .status(403)
              .json({"error": 'not allow to run the program.'});
          return;
        }
        Process.run(program, programArgs, environment: programEnvironment)
            .then((pr) {
          var m = {
            'stdout': pr.stdout,
            'stderr': pr.stderr,
            'exitcode': pr.exitCode
          };
          if (!responseClosed) {
            responseClosed = true;
            request.response.json(m);
          }
        });
        Future.delayed(Duration(seconds: timeOut), () {
          if (!responseClosed) {
            responseClosed = true;
            request.response.json({'error': 'timeout'});
          }
        });
      });
    });

    app.post('/run/').where(checkRequestToken).listen((request) async {
      var uuid = uuidGenerator.v4();
      request.payload().then((m) {
        final program = m['program'] ?? "";
        final programArgs = m['args']?.cast<String>() ?? List<String>();
        final stdin = m['stdin']?.toString() ?? "";
        if (program == "") {
          request.response.status(400).json({"error": 'no program to run.'});
          return;
        }
        var programEnvironment = Map<String, String>()
          ..addAll(Platform.environment);
        programEnvironment['cid'] = getCID(request);
        if (allowedProgram.contains(program)) {
          Process.start(program, programArgs, environment: programEnvironment)
              .then((Process process) {
            process.stdin.write(stdin);
            process.stdin.close();
            processResult[uuid] = Map<String, String>();
            processResult[uuid]['stdout'] = '';
            processResult[uuid]['stderr'] = '';
            processResult[uuid]['exitcode'] = '';
            processResult[uuid]['error'] = '';
            processResult[uuid]['pid'] = process.pid.toString();
            runningProcess.add(program);
            process.stdout.transform(utf8.decoder).listen((data) {
              processResult[uuid]['stdout'] += data;
            });
            process.stderr.transform(utf8.decoder).listen((data) {
              processResult[uuid]['stderr'] += data;
            });
            process.exitCode.then((exitcode) {
              processResult[uuid]['exitcode'] += exitcode.toString();
              runningProcess.remove(program);
            });
            Future.delayed(Duration(seconds: timeOut), () {
              process.kill();
              processResult[uuid]['error'] = 'timeout, kill by sigterm';
            });
          });
          request.response.json({"uuid": uuid});
        } else {
          request.response
              .status(403)
              .json({"error": 'not allow to run the program.'});
        }
      });
    });

    app.get('/run/:uuid').where(checkRequestToken).listen((request) {
      var uuid = request.param('uuid');
      var m = {};
      if (processResult.containsKey(uuid)) {
        m = {
          'stdout': processResult[uuid]['stdout'],
          'stderr': processResult[uuid]['stderr'],
          'exitcode': processResult[uuid]['exitcode'],
        };
        request.response.json(m);
      } else {
        request.response.status(404).json({"error": "not found"});
      }
    });

    app.delete('/run/:id').listen((request) {
      request.response.header('Content-Type', 'application/json').send('{}');
    });

    app.post('/file/').where(checkRequestToken).listen((request) {
      request.payload().then((m) {
        final filePath = m['path'].toString();

        var f = File(filePath);
        final absPath = f.absolute.uri.toString().substring(7);
        for (var l in allowedPath) {
          if (absPath.startsWith(l)) {
            f = File(absPath);
            final content = f.readAsStringSync();
            request.response.json({"content": content});
            return;
          }
        }
      });

    });
    app.post('/file/').where(checkRequestToken).listen((request) {
      request.payload().then((m) {
        final filePath = m['path'].toString();
        final content = m['content'].toString();

        var f = File(filePath);
        final absPath = f.absolute.uri.toString().substring(7);
        for (var l in allowedPath) {
          if (absPath.startsWith(l)) {
            f = File(absPath);
            f.createSync(recursive: true);
            f.writeAsStringSync(content);
            request.response.json({"message": 'file updated/created.'});
            return;
          }
        }

        request.response
            .status(403)
            .json({"error": 'Not allowed to update/create file.'});
        return;
      });
    });

    app.delete('/file/').where(checkRequestToken).listen((request) {
      request.payload().then((m) {
        final filePath = m['path']?.toString() ?? "";
        if (filePath == '') {
          request.response.status(400).json({'error': 'no path'});
          return;
        }
        var f = File(filePath);
        final absPath = f.absolute.uri.toString().substring(7);
        print(absPath);
        for (var l in allowedPath) {
          if (absPath.startsWith(l)) {
            f = File(absPath);
            if (f.existsSync()) {
              f.deleteSync();
            }
            request.response.json({"message": 'file deleted.'});
            return;
          }
        }
        request.response
            .status(403)
            .json({"error": 'Not allowed to delete the file.'});
        return;
      });
    });
  });
}
