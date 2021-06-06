import "dart:async";
import "dart:io";
import "dart:convert";
import 'package:yaml/yaml.dart';
import 'package:uuid/uuid.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:alfred/alfred.dart';

main(List<String> args) async {
  final log = Logger("main");
  final parser = new ArgParser();
  parser.addMultiOption('path',
      abbr: "p", help: 'The path which is allowed to write the files.');
  parser.addMultiOption('exec',
      abbr: "e", help: 'the binary which is allowed to execute.');
  parser.addOption('allow-origin', defaultsTo: '');
  parser.addMultiOption('static', abbr: "s", help: 'static files');
  parser.addOption('config', abbr: "c", help: 'config file', defaultsTo: '');
  parser.addOption('prefix', help: 'prefix', defaultsTo: '');
  parser.addOption('token', abbr: "t", help: 'token', defaultsTo: '');
  parser.addOption('timeout', help: 'timeout', defaultsTo: '300');
  parser.addOption('salt', defaultsTo: '');

  parser.addOption('port', defaultsTo: '3000');

  parser.addFlag('file-support', defaultsTo: false);
  parser.addFlag('debug', defaultsTo: false);

  YamlMap? yamlMap = YamlMap();
  var processResult = Map<String, Map<String, String>>();
  var runningProcess = [];

  final uuidGenerator = Uuid();
  final argResults = parser.parse(args);
  final token = argResults['token'];
  final salt = argResults['salt'];
  final debug = argResults['debug'];
  final allowedProgram = argResults['exec'] as List<String>?;
  final allowedPath = argResults['path'] as List<String>?;
  final timeOut = int.tryParse(argResults['timeout']) ?? 300;
  final prefix = argResults['prefix'].toString();
  final fileSupport = argResults['file-support'];
  final allowOrigin = argResults['allow-origin'];
  final hasAllowOrigin = allowOrigin != '';
  final port = int.tryParse(argResults['port']) ?? 3000;
  final app = Alfred();

  if (argResults['config'] != '') {
    final f = File(argResults['config']);
    yamlMap = loadYaml(f.readAsStringSync());
  }

  var configListString = Map<String, List<String?>?>();

  for (final i in ['path', 'exec']) {
    configListString[i] = argResults[i];
    if (yamlMap![i] != null) {
      for (var j in yamlMap[i]) {
        if (configListString[i] != null) {
          configListString[i]?.add(j);
        }
      }
    }
  }

  print(configListString);

  final cookiePath = prefix.length == 0 ? "/" : prefix;

  bool setCookie(HttpRequest req,HttpResponse res,String name, String value){
    var found = false;
    for(var cookie in req.cookies){
      if(cookie.name == name){
        found = true;
        return found;
      }
    }
    final cookie = Cookie(name, value);
    cookie.path = cookiePath;
    res.cookies.add(cookie);
    return found;
    }

  app.all('*', (req, res) {
    final isNew = setCookie(req,res, 'cid', uuidGenerator.v4());
  });

  for (final i in argResults['static']) {
    final s = i.toString();
    final pos = s.indexOf('=');
    print("$prefix,${s.substring(0, pos)}, ${s.substring(pos + 1)}");
    app.get(prefix + s.substring(0, pos),
        (req, res) => Directory(s.substring(pos + 1)));
  }

  app.post(prefix + '/runsync', (req, res) async {
    final body = (await req.body)!;
    Map<String, dynamic> jsonMap = json.decode(body as String);
    final program = jsonMap['program'] ?? "";
    final programArgs = jsonMap['args']?.cast<String>() ?? <String>[];
    if (program == "") {
      return {"error": "no program to run"};
    }

    var programEnvironment = Map<String, String>()
      ..addAll(Platform.environment);
    /* programEnvironment['cid'] = getClientID(ctx); */
    if (!allowedProgram!.contains(program)) {
      return {"error": 'not allow to run the program.'};
    }
    final pr = await Future.any([
      Process.run(program, programArgs, environment: programEnvironment),
      Future<ProcessResult>.delayed(
          Duration(seconds: timeOut), () => ProcessResult(-1, -1, "", ""))
    ]);
    if (pr.pid == -1) {
      return {"error": "time out"};
    } else {
      return {
        'stdout': pr.stdout,
        'stderr': pr.stderr,
        'exitcode': pr.exitCode
      };
    }
  });

  app.post(prefix + '/run', (req, res) async {
    final body = (await req.body)!;
    Map<String, dynamic> jsonMap = json.decode(body as String);
    final uuid = uuidGenerator.v4();
    final program = jsonMap['program'] ?? "";
    final programArgs = jsonMap['args']?.cast<String>() ?? <String>[];
    final stdin = jsonMap['stdin']?.toString() ?? "";
    if (program == "") {
      return {"error": 'not allow to run the program.'};
    }
    var programEnvironment = Map<String, String>()
      ..addAll(Platform.environment);
    /* programEnvironment['cid'] = getClientID(ctx); */

    if (!allowedProgram!.contains(program)) {
      return {"error": 'not allow to run the program.'};
    }
    Process.start(program, programArgs, environment: programEnvironment)
        .then((Process process) {
      process.stdin.write(stdin);
      process.stdin.close();
      processResult[uuid] = Map<String, String>();
      processResult[uuid]!['stdout'] = '';
      processResult[uuid]!['stderr'] = '';
      processResult[uuid]!['exitcode'] = '';
      processResult[uuid]!['error'] = '';
      processResult[uuid]!['pid'] = process.pid.toString();
      runningProcess.add(program);
      process.stdout.transform(utf8.decoder).listen((data) {
        processResult[uuid]!['stdout'] = processResult[uuid]!['stdout']! + data;
      });
      process.stderr.transform(utf8.decoder).listen((data) {
        processResult[uuid]!['stderr'] = processResult[uuid]!['stderr']! + data;
      });
      process.exitCode.then((exitcode) {
        processResult[uuid]!['exitcode'] =
            processResult[uuid]!['exitcode']! + exitcode.toString();
        runningProcess.remove(program);
      });
    });
    return {"uuid": uuid};
  });

  app.get(prefix + '/run/', (req, res) async {
    return {"uuid": processResult.keys.toList()};
  });
  app.get(prefix + '/run/:uuid', (req, res) async {
    final String? uuid = req.params['uuid'];
    if (uuid == 'not found') {
      return {"error": "not found"};
    }
    if (processResult.containsKey(uuid)) {
      var ret = {
        'stdout': processResult[uuid!]!['stdout'],
        'stderr': processResult[uuid]!['stderr'],
        'exitcode': processResult[uuid]!['exitcode'],
      };
      if (processResult[uuid]!.containsKey('error')) {
        ret['error'] = processResult[uuid]!['error'];
      }
      return ret;
    } else {
      return {"error": "not found"};
    }
  });

  if (fileSupport) {
    app.get(prefix + '/file', (req, res) async {
      final filePath = req.uri.queryParameters['path']!;

      final f = File(filePath);
      final absPath = f.absolute.uri.toString().substring(7);
      for (final l in allowedPath!) {
        if (absPath.startsWith(l)) {
          final f = File(absPath);
          final content = f.readAsStringSync();
          return {"content": content};
        }
      }
    });

    app.post(prefix + '/file', (req, res) async {
      final body = (await req.body)!;
      Map<String, dynamic> jsonMap = json.decode(body as String);
      final filePath = jsonMap['path'].toString();
      final fileType = jsonMap['type'].toString();
      final content = jsonMap['content'].toString();

      final f = File(filePath);
      print(fileType);
      final absPath = f.absolute.uri.toString().substring(7);
      for (final l in allowedPath!) {
        if (absPath.startsWith(l)) {
          final f = File(absPath);
          f.createSync(recursive: true);
          if (fileType == 'json') {
            f.writeAsStringSync(jsonEncode(jsonMap['content']));
          } else {
            f.writeAsStringSync(content);
          }
          return {"message": 'file updated/created.'};
        }
      }
      return {"error": 'Not allowed to update/create file.'};
    });

    app.delete(prefix + '/file', (req, res) async {
      final body = (await req.body)!;
      Map<String, dynamic> jsonMap = json.decode(body as String);
      final filePath = jsonMap['path'].toString();

      if (filePath == '') {
        return {'error': 'no path'};
      }
      final f = File(filePath);
      final absPath = f.absolute.uri.toString().substring(7);
      print(absPath);
      for (final l in allowedPath!) {
        if (absPath.startsWith(l)) {
          final f = File(absPath);
          if (f.existsSync()) {
            f.deleteSync();
          }
          return {"message": 'file deleted.'};
        }
      }
      return {"error": 'Not allowed to delete the file.'};
    });
  }

  app.listen(port);
}
