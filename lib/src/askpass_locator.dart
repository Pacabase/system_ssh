import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

@Native<Pointer<Utf16> Function()>(symbol: 'system_ssh_askpass_locator')
external Pointer<Utf16> _locator();

/// The password helper program the build hook bundled on Windows, or null
/// where there is none: on other systems, 32-bit Windows, or an app shipped
/// without it. Tests set it to null to see what happens then.
String? bundledWindowsHelper = _find();

String? _find() {
  if (!Platform.isWindows) return null;
  try {
    final library = _locator().toDartString();
    if (library.isEmpty) return null;
    final helper = '${File(library).parent.path}\\system_ssh_askpass.exe';
    return File(helper).existsSync() ? helper : null;
  } catch (exception) {
    // No locator library was bundled, so its function doesn't resolve.
    return null;
  }
}
