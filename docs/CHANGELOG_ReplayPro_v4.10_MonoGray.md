# ReplayPro v4.10 — پنل جدید Mono Gray (هم‌شکل Risk Manager)
فقط ظاهر و چیدمان پنل روی چارت عوض شده؛ منطق ریپلی/معامله/ریسک بدون تغییر نسبت به v4.00 (بدون DLL). **کامپایل نشده.**

## تغییرها
1. تم Mono Gray (همان پالت Risk Manager): پس‌زمینه خاکستری روشن، دکمه‌ها خاکستری با کادر، دکمه‌های روشن/خاموش (Play, Prev Day, Week Map, Key Time) هنگام فعال بودن فیروزه‌ای.
2. چیدمان مثل داشبورد RM: هدر، سه تب (Trade / Tools)، باکس وضعیت (زمان، بالانس، Float، Batch، روز)، باکس اطلاعات معامله‌ی انتخاب‌شده، باکس پیام.
3. دو تب: Trade و Tools. تب Trade: Next Bar/Play، +1m/+5m/+15m/+1h، Slow/Fast/Exit، BUY/SELL، Close Last/All، Risk%/TP(R)، تگ استراتژی/ستاپ، ADD PEND LINE / CANCEL PEND.
4. تب Tools: Prev Day/Week Map/Key Time، تاریخ + Cal + Go، Price + Set SL/Set TP، Step$/Dist$ + Trail، Dashboard / Save (همان SaveSummary) / Reset.
5. دکمه و پوشش Stats حذف شد (چشمک می‌زد؛ داشبورد جایگزین است).
6. عرض پنل ۲۲۰ پیکسل؛ عرض دکمه‌ها طوری است که لبه‌ی چپ و راست با لبه‌ی باکس‌ها یکی است. پنجره‌ی تقویم هم با همین تم.
7. روش اجرا همان قبلی است (BUY/SELL، خط SL قابل‌درگ، Set SL/TP، خط Pending).

## دست‌نخورده
رنگ چارت و ورودی‌ها (ColBack و …)، لاگ‌ها، Key Time، Dashboard، فایل‌های CSV.

## نصب
`MQL4\Scripts\ReplayPro_v4.10.mq4` را کپی و کامپایل کن (v4.00 کنارش می‌ماند). اگر کامپایل خطا داد، متن خطا را بفرست.
