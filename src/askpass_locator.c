// Says where it was installed, so Dart finds the helper program bundled
// beside it: code assets have no path of their own at runtime.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static wchar_t path[32768];

__declspec(dllexport) const wchar_t *system_ssh_askpass_locator(void) {
  HMODULE self = NULL;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCWSTR)&system_ssh_askpass_locator, &self) ||
      GetModuleFileNameW(self, path, 32768) == 0) {
    path[0] = L'\0';
  }
  return path;
}
