# ReplayPro v4.00 — بدون DLL
تغییرها نسبت به نسخه‌ی FINAL VERSION (v3.75):
1. حذف کامل `#import` (shell32 و user32). دیگر «Allow DLL imports» لازم نیست و باید خاموش بماند.
2. Refresh چارت آفلاین: به‌جای PostMessageA، تابع ChartSetSymbolPeriod روی همه‌ی چارت‌های باز آفلاین (نماد *_R) صدا زده می‌شود. (آزمایش RPTest: ۲ کندل در ثانیه، روان، ابزار رسم‌شده می‌ماند.)
3. دکمه‌ی Dashboard: فقط RP_data.txt را به‌روز می‌کند. فایل RP_Dashboard.html را خودت در Chrome باز کن (بوکمارک) و F5 بزن؛ اسکریپت بدون DLL نمی‌تواند مرورگر را باز کند.
4. پیام شروع «Please enable Allow DLL imports» حذف شد.
بقیه‌ی منطق (ریپلی، پنل، ریسک، تگ‌ها، لاگ، Key Time، تقویم) دست‌نخورده. کامپایل نشده.
نصب: MQL4\Scripts\ReplayPro.mq4 را جایگزین کن و کامپایل کن (ReplayPro.ex4 قدیمی هم بازنویسی می‌شود).
