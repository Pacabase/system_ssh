import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  test('entries are equal only with the same kind and line', () {
    expect(const SshProgress('x'), const SshProgress('x'));
    expect(const SshProgress('x').hashCode, const SshProgress('x').hashCode);
    expect(const SshProgress('x'), isNot(const SshMessage('x')));
    expect(const SshMessage('x'), isNot(const SshMessage('y')));
  });

  test('a failed forward is equal only with the same kind and reason too', () {
    const failed = SshForwardUnreachable('x', reason: 'Connection refused');

    expect(
      failed,
      const SshForwardUnreachable('x', reason: 'Connection refused'),
    );
    expect(
      failed.hashCode,
      const SshForwardUnreachable('x', reason: 'Connection refused').hashCode,
    );
    expect(
      failed,
      isNot(const SshForwardUnreachable('x', reason: 'No route to host')),
    );
    expect(failed, isNot(const SshForwardProhibited('x')));
    expect(failed, isNot(const SshMessage('x')));
  });

  test('each kind names itself and its line', () {
    expect('${const SshProgress('a')}', 'SshProgress(a)');
    expect('${const SshMessage('b')}', 'SshMessage(b)');
    expect(
      '${const SshForwardUnreachable('c', reason: 'r')}',
      'SshForwardUnreachable(c)',
    );
    expect('${const SshForwardProhibited('d')}', 'SshForwardProhibited(d)');
  });
}
