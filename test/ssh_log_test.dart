import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  test('entries are equal only with the same kind and line', () {
    expect(const SshProgress('x'), const SshProgress('x'));
    expect(const SshProgress('x').hashCode, const SshProgress('x').hashCode);
    expect(const SshProgress('x'), isNot(const SshMessage('x')));
    expect(const SshMessage('x'), isNot(const SshMessage('y')));
  });

  test('a failed forward is equal only with the same reason too', () {
    const failed = SshForwardFailed('x', reason: 'Connection refused');

    expect(failed, const SshForwardFailed('x', reason: 'Connection refused'));
    expect(
      failed.hashCode,
      const SshForwardFailed('x', reason: 'Connection refused').hashCode,
    );
    expect(
      failed,
      isNot(const SshForwardFailed('x', reason: 'administratively prohibited')),
    );
    expect(failed, isNot(const SshMessage('x')));
  });

  test('each kind names itself and its line', () {
    expect('${const SshProgress('a')}', 'SshProgress(a)');
    expect('${const SshMessage('b')}', 'SshMessage(b)');
    expect(
      '${const SshForwardFailed('c', reason: 'r')}',
      'SshForwardFailed(c)',
    );
  });
}
