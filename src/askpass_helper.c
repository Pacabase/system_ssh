// The SSH_ASKPASS helper ssh runs on Windows. ssh passes the prompt as an
// argument; the helper sends it, after the token, to the app listening on
// the loopback port in its environment, and prints the app's answer for ssh.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

// 'y', the most ssh reads of an answer (1023 bytes), and the newline.
#define MAX_ANSWER 1025

static const char alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *base64(const unsigned char *in, size_t length) {
  char *out = malloc((length + 2) / 3 * 4 + 1);
  if (out == NULL) return NULL;
  size_t o = 0;
  for (size_t i = 0; i < length; i += 3) {
    unsigned long n = (unsigned long)in[i] << 16;
    if (i + 1 < length) n |= (unsigned long)in[i + 1] << 8;
    if (i + 2 < length) n |= in[i + 2];
    out[o++] = alphabet[(n >> 18) & 63];
    out[o++] = alphabet[(n >> 12) & 63];
    out[o++] = i + 1 < length ? alphabet[(n >> 6) & 63] : '=';
    out[o++] = i + 2 < length ? alphabet[n & 63] : '=';
  }
  out[o] = '\0';
  return out;
}

static int send_all(SOCKET s, const char *data, size_t length) {
  while (length > 0) {
    int sent = send(s, data, (int)length, 0);
    if (sent <= 0) return 0;
    data += sent;
    length -= (size_t)sent;
  }
  return 1;
}

static int env_equals(const wchar_t *name, const wchar_t *value) {
  wchar_t buffer[16];
  DWORD length = GetEnvironmentVariableW(name, buffer, 16);
  return length > 0 && length < 16 && wcscmp(buffer, value) == 0;
}

int wmain(int argc, wchar_t **argv) {
  // A notice ssh doesn't wait on, such as to touch a key, and a yes/no
  // question, which a tunnel never needs.
  if (env_equals(L"SSH_ASKPASS_PROMPT", L"none")) return 0;
  if (env_equals(L"SSH_ASKPASS_PROMPT", L"confirm")) return 1;

  char port[16], token[128];
  DWORD port_length =
      GetEnvironmentVariableA("SYSTEM_SSH_ASKPASS_PORT", port, sizeof port);
  DWORD token_length =
      GetEnvironmentVariableA("SYSTEM_SSH_ASKPASS_TOKEN", token, sizeof token);
  if (port_length == 0 || port_length >= sizeof port || token_length == 0 ||
      token_length >= sizeof token) {
    return 1;
  }

  // Windows' ssh quotes the prompt only when it holds a space, so a prompt
  // with tabs but none arrives split there; rejoin the pieces.
  size_t prompt_length = 1;
  for (int i = 1; i < argc; i++) prompt_length += wcslen(argv[i]) + 1;
  wchar_t *prompt = calloc(prompt_length, sizeof(wchar_t));
  if (prompt == NULL) return 1;
  for (int i = 1; i < argc; i++) {
    if (i > 1) wcscat(prompt, L" ");
    wcscat(prompt, argv[i]);
  }
  int utf8_length =
      WideCharToMultiByte(CP_UTF8, 0, prompt, -1, NULL, 0, NULL, NULL);
  if (utf8_length <= 0) return 1;
  char *utf8 = malloc((size_t)utf8_length);
  if (utf8 == NULL) return 1;
  WideCharToMultiByte(CP_UTF8, 0, prompt, -1, utf8, utf8_length, NULL, NULL);
  free(prompt);
  char *encoded = base64((const unsigned char *)utf8, (size_t)utf8_length - 1);
  free(utf8);
  if (encoded == NULL) return 1;

  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) return 1;
  struct sockaddr_in address;
  memset(&address, 0, sizeof address);
  address.sin_family = AF_INET;
  address.sin_port = htons((u_short)atoi(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr *)&address, sizeof address) != 0) return 1;

  if (!send_all(s, token, token_length) || !send_all(s, "\n", 1) ||
      !send_all(s, encoded, strlen(encoded)) || !send_all(s, "\n", 1)) {
    return 1;
  }
  free(encoded);

  static char answer[MAX_ANSWER];
  size_t length = 0;
  int complete = 0;
  while (!complete && length < MAX_ANSWER) {
    int received = recv(s, answer + length, (int)(MAX_ANSWER - length), 0);
    if (received <= 0) break;
    char *end = memchr(answer + length, '\n', (size_t)received);
    length += (size_t)received;
    if (end != NULL) {
      length = (size_t)(end - answer);
      complete = 1;
    }
  }
  closesocket(s);

  int answered = complete && length > 0 && answer[0] == 'y';
  if (answered) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD written;
    answered = WriteFile(out, answer + 1, (DWORD)(length - 1), &written, NULL) &&
               WriteFile(out, "\n", 1, &written, NULL);
  }
  SecureZeroMemory(answer, sizeof answer);
  return answered ? 0 : 1;
}
