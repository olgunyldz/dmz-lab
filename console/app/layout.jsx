import "./globals.css";

export const metadata = {
  title: "DMZ Lab konsolu",
  description: "Web ve mobil kanal test konsolu",
};

export const viewport = {
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }) {
  return (
    <html lang="tr">
      <body>{children}</body>
    </html>
  );
}
