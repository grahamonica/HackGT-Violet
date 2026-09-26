import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Provider Portal",
  description: "Clinical view of Violet recognition and visit data.",
  icons: { icon: "/violet-logo.png" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
