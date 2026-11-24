import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// On Windows, builds the program ssh runs as `SSH_ASKPASS`, and a library
/// that tells Dart where it was installed. Elsewhere the package writes a
/// shell script at runtime, so nothing is built: Dart can't bundle a program
/// there yet (macOS rewrites a bundled file as a library; Linux drops its
/// executable bit).
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.windows) return;

    final logger = Logger('system_ssh')
      ..onRecord.listen((record) => print(record.message));
    try {
      await CBuilder.executable(
        name: 'system_ssh_askpass',
        sources: ['src/askpass_helper.c'],
        libraries: ['ws2_32'],
      ).run(input: input, output: output, logger: logger);
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'system_ssh_askpass',
          linkMode: DynamicLoadingBundled(),
          file: input.outputDirectory.resolve(
            os.executableFileName('system_ssh_askpass'),
          ),
        ),
      );
      await CBuilder.library(
        name: 'system_ssh_askpass_locator',
        assetName: 'src/askpass_locator.dart',
        sources: ['src/askpass_locator.c'],
      ).run(input: input, output: output, logger: logger);
    } catch (exception) {
      // Without a C compiler, prompts go through the .cmd helper instead.
      print(
        'system_ssh: could not build the Windows password helper, so prompts '
        'use the .cmd helper and ask less: $exception',
      );
    }
  });
}
