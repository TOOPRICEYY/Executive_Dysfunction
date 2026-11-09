import Foundation
import CryptoKit

/// Client-side friction only. Server-side challenge/policy checks remain
/// mandatory; OCR and automated keystrokes cannot reliably be distinguished.
enum BlockPageTypingGuard {
    static let script = """
    document.querySelectorAll('form.pause-rule').forEach(form => {
      const field = form.querySelector('textarea');
      const buttons = form.querySelectorAll('button[type="submit"]');
      let accepted = '';
      const hasIntent = () => !!form.querySelector('input[name="intent"]:checked');
      const refresh = () => buttons.forEach(button => button.disabled = accepted.trim().length === 0 || !hasIntent());
      form.querySelectorAll('input[name="intent"]').forEach(input => input.addEventListener('change', refresh));
      const reject = event => { event.preventDefault(); field.value = accepted; };
      field.addEventListener('paste', reject);
      field.addEventListener('drop', reject);
      field.addEventListener('beforeinput', event => {
        const typing = event.inputType === 'insertText' && Array.from(event.data || '').length === 1;
        const deletion = (event.inputType || '').startsWith('delete');
        const newline = event.inputType === 'insertLineBreak';
        if (!event.isTrusted || field.value !== accepted || !(typing || deletion || newline)) reject(event);
      });
      field.addEventListener('input', event => {
        const typing = event.inputType === 'insertText' && Array.from(event.data || '').length === 1;
        const deletion = (event.inputType || '').startsWith('delete');
        if (event.isTrusted && (typing || deletion || event.inputType === 'insertLineBreak')) accepted = field.value;
        else field.value = accepted;
        refresh();
      });
      form.addEventListener('submit', event => {
        if (!accepted.trim() || field.value !== accepted || !hasIntent()) reject(event);
      });
      refresh();
    });
    """

    static var cspSource: String {
        "'sha256-\(Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString())'"
    }
}
