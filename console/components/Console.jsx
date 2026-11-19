// DMZ Lab konsolu. Sayfa yoluna göre ekran seçilir:
//   /         kanal kartları (giriş)
//   /web      Web girişi, sonra hesap işlemleri (kanal: web)
//   /mobil    Mobil uygulama (giriş sihirbazı, sonra alt menülü uygulama; kanal: mobile)
//   /islemler Hesap işlemleri (giriş yapılmış kanal)
//   /sms      Lab SMS kutusu
// Her sayfanın altında istek akışı paneli: her isteğin geçtiği hat, süre ve iz linki.
"use client";
import { usePathname } from "next/navigation";
import { WebPage } from "./Web.jsx";
import { MobilePage } from "./Mobile.jsx";
import { OpsPage, SmsPage, HomePage } from "./Pages.jsx";
import { Shell } from "./Ui.jsx";
import { CustomerCreatePage } from "./CustomerCreate.jsx";

export default function Console() {
  const path = usePathname() || "/";
  // Her sayfa ortak kabuğun (header/footer) içinde. Mobil uygulama telefon çerçevesi olarak kabuğun içine yerleşir.
  if (path === "/web") return <WebPage />;
  if (path === "/mobil") return <Shell><div className="phone-stage"><MobilePage /></div></Shell>;
  if (path === "/islemler") return <OpsPage />;
  if (path === "/sms") return <SmsPage />;
  if (path === "/musteri-ekle") return <CustomerCreatePage />;
  return <HomePage />;
}
