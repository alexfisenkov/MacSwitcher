# Частотные данные

`macos/Sources/RuSwitcher/Resources/{ru,en}.tsv` — производные данные
[FrequencyWords](https://github.com/hermitdave/FrequencyWords), автор Hermit Dave,
исходные частоты OpenSubtitles 2018. Данные распространяются под
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
Это отдельная лицензия данных, MIT в корне относится к программному коду.

Изменения MacSwitcher: Unicode NFC, нижний регистр, фильтрация алфавита и длины,
объединение дубликатов максимальной частотой, до 200 000 частотных словоформ
каждого языка. Счётчик означает частоту в корпусе, а не вероятность или нормативность слова.
Субтитры содержат разговорные, редкие и ненормативные слова.

Точный upstream commit, хеш исходного файла и хеш результата находятся в
`manifest.json`. Воспроизводимый импорт: `script/import_dictionaries.py`.
Производные TSV сохраняют CC BY-SA 4.0. Исходные данные не являются личным
словарём пользователя и не содержат его историю набора.
