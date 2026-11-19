// Lab SMS kutusu: her kanalın son OTP'si (yalnız /sms ekranında gösterilir).
const box = globalThis.__consoleSms ?? (globalThis.__consoleSms = {});

export function rememberSms(channel, code) {
  box[channel] = { demoOtp: code, at: new Date().toLocaleTimeString("tr-TR") };
}
export function smsBox() {
  return { web: box.web ?? null, mobile: box.mobile ?? null };
}
