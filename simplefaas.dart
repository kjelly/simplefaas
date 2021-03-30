import "dart:async";
import "dart:io";
import "dart:convert";
import 'package:yaml/yaml.dart';
import 'package:uuid/uuid.dart';
import 'package:args/args.dart';
import 'package:jaguar/jaguar.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

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

  var yamlMap = YamlMap();
  var processResult = Map<String, Map<String, String>>();
  var runningProcess = [];

  final uuidGenerator = Uuid();
  final argResults = parser.parse(args);
  final token = argResults['token'];
  final salt = argResults['salt'];
  final debug = argResults['debug'];
  final allowedProgram = argResults['exec'] as List<String>;
  final allowedPath = argResults['path'] as List<String>;
  final defaultPort = int.tryParse(argResults['port'] ?? '3000') ?? 3000;
  final timeOut = int.tryParse(argResults['timeout']) ?? 300;
  final prefix = argResults['prefix'];
  final fileSupport = argResults['file-support'];
  final server = Jaguar(port: defaultPort);
  final allowOrigin = argResults['allow-origin'];
  final hasAllowOrigin = allowOrigin != '';

  if (argResults['config'] != '') {
    final f = File(argResults['config']);
    yamlMap = loadYaml(f.readAsStringSync());
  }

  var configListString = Map<String, List<String>>();

  for (final i in ['path', 'exec']) {
    configListString[i] = argResults[i];
    if (yamlMap[i] != null) {
      for (var j in yamlMap[i]) {
        if (configListString[i] != null) {
          configListString[i]?.add(j);
        }
      }
    }
  }

  print(configListString);

  String getClientID(Context ctx) {
    final keys = ['cid1', 'cid2', 'cid3', 'cid4'];
    for (var i in keys) {
      if (!ctx.cookies.containsKey(i)) {
        return "";
      }
    }
    var hash = salt;
    for (var i in keys) {
      hash =
          sha256.convert(utf8.encode(ctx.cookies[i].value + hash)).toString();
    }
    return hash;
  }

  void setCookie(Context ctx) {
    for (final i in ['cid1', 'cid2', 'cid3', 'cid4']) {
      if (!ctx.cookies.containsKey(i)) {
        ctx.response.cookies.add(Cookie(i, uuidGenerator.v4()));
      }
    }
  }

  void setAllowOrigin(Context ctx) {
    if (hasAllowOrigin) {
      ctx.response.headers.add('Access-Control-Allow-Origin', '*');
    }
  }

  void checkRequestToken(Context ctx) async {
    final headerToken = ctx.headers['token'] ?? <String>[];
    if (token != '' && !headerToken.contains(token)) {
      throw Response.json({"error": 'Not allow to access.'},
          statusCode: HttpStatus.forbidden);
    }
  }

  void logRequest(Context ctx) async {
    if (debug) {
      log.info("request: ${ctx.path} ${ctx.pathParams}");
    }
  }

  final beforeFunctions = [checkRequestToken, logRequest];
  final afterFunctions = [setCookie, setAllowOrigin];

  for (final i in argResults['static']) {
    final s = i.toString();
    final pos = s.indexOf('=');
    print("$prefix,${s.substring(0, pos)}, ${s.substring(pos + 1)}");
    server.staticFiles(prefix + s.substring(0, pos), s.substring(pos + 1));
  }

  server.postJson(prefix + '/runsync', (Context ctx) async {
    Map<String, dynamic> jsonMap = await ctx.bodyAsJsonMap();
    final program = jsonMap['program'] ?? "";
    final programArgs = jsonMap['args']?.cast<String>() ?? <String>[];
    if (program == "") {
      return {"error": "no program to run"};
    }

    var programEnvironment = Map<String, String>()
      ..addAll(Platform.environment);
    programEnvironment['cid'] = getClientID(ctx);
    if (!allowedProgram.contains(program)) {
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
  }, before: beforeFunctions, after: afterFunctions);

  server.postJson(prefix + '/run', (Context ctx) async {
    Map<String, dynamic> jsonMap = await ctx.bodyAsJsonMap();
    final uuid = uuidGenerator.v4();
    final program = jsonMap['program'] ?? "";
    final programArgs = jsonMap['args']?.cast<String>() ?? <String>[];
    final stdin = jsonMap['stdin']?.toString() ?? "";
    if (program == "") {
      return {"error": 'not allow to run the program.'};
    }
    var programEnvironment = Map<String, String>()
      ..addAll(Platform.environment);
    programEnvironment['cid'] = getClientID(ctx);

    if (!allowedProgram.contains(program)) {
      return {"error": 'not allow to run the program.'};
    }
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
    });
    return {"uuid": uuid};
  }, before: beforeFunctions, after: afterFunctions);

  server.getJson(prefix + '/run/:uuid', (Context ctx) async {
    final String uuid = ctx.pathParams.get('uuid', 'not found');
    if (uuid == 'not found') {
      return {"error": "not found"};
    }
    if (processResult.containsKey(uuid)) {
      var ret = {
        'stdout': processResult[uuid]['stdout'],
        'stderr': processResult[uuid]['stderr'],
        'exitcode': processResult[uuid]['exitcode'],
      };
      if (processResult[uuid].containsKey('error')) {
        ret['error'] = processResult[uuid]['error'];
      }
      return ret;
    } else {
      return {"error": "not found"};
    }
  }, before: beforeFunctions, after: afterFunctions);

  if (fileSupport) {
    server.getJson(prefix + '/file', (Context ctx) async {
      Map<String, dynamic> jsonMap = await ctx.bodyAsJsonMap();
      final filePath = jsonMap['path'].toString();

      final f = File(filePath);
      final absPath = f.absolute.uri.toString().substring(7);
      for (final l in allowedPath) {
        if (absPath.startsWith(l)) {
          final f = File(absPath);
          final content = f.readAsStringSync();
          return {"content": content};
        }
      }
    }, before: beforeFunctions, after: afterFunctions);

    server.postJson(prefix + '/file', (Context ctx) async {
      Map<String, dynamic> jsonMap = await ctx.bodyAsJsonMap();
      final filePath = jsonMap['path'].toString();
      final fileType = jsonMap['type'].toString();
      final content = jsonMap['content'].toString();

      final f = File(filePath);
      print(fileType);
      final absPath = f.absolute.uri.toString().substring(7);
      for (final l in allowedPath) {
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
    }, before: beforeFunctions, after: afterFunctions);

    server.deleteJson(prefix + '/file', (Context ctx) async {
      Map<String, dynamic> jsonMap = await ctx.bodyAsJsonMap();
      final filePath = jsonMap['path'].toString();

      if (filePath == '') {
        return {'error': 'no path'};
      }
      final f = File(filePath);
      final absPath = f.absolute.uri.toString().substring(7);
      print(absPath);
      for (final l in allowedPath) {
        if (absPath.startsWith(l)) {
          final f = File(absPath);
          if (f.existsSync()) {
            f.deleteSync();
          }
          return {"message": 'file deleted.'};
        }
      }
      return {"error": 'Not allowed to delete the file.'};
    }, before: beforeFunctions, after: afterFunctions);
  }

  server.post(prefix + '/setcookie', (Context ctx) async {
    return 'set cookie';
  }, before: beforeFunctions, after: afterFunctions);

  await server.serve(logRequests: debug);
}
