import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// On Windows, ships the program ssh runs as `SSH_ASKPASS`, and a library
/// that tells Dart where it was installed. Both are built ahead of time into
/// `windows/`, by CI's `windows-askpass` job, so building an app needs no C
/// compiler. Elsewhere the package writes a shell script at runtime, so
/// nothing ships: Dart can't bundle a program there yet (macOS rewrites a
/// bundled file as a library; Linux drops its executable bit).
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (code.targetOS != OS.windows) return;
    final folder = switch (code.targetArchitecture) {
      Architecture.x64 => 'x64',
      Architecture.arm64 => 'arm64',
      // 32-bit Windows gets no helper, so its tunnels don't ask.
      _ => null,
    };
    if (folder == null) return;

    for (final (name, file) in [
      ('src/askpass_locator.dart', 'system_ssh_askpass_locator.dll'),
      ('system_ssh_askpass', 'system_ssh_askpass.exe'),
    ]) {
      final uri = input.packageRoot.resolve('windows/$folder/$file');
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: name,
          linkMode: DynamicLoadingBundled(),
          file: uri,
        ),
      );
      output.dependencies.add(uri);
    }
  });
}
