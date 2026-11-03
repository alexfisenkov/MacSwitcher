# MacSwitcher Windows

Windows-порт текущего MacSwitcher в том же репозитории. Канон: ../docs/windows-port/design.md и contracts.md, текущие Swift policy/gold и dictionaries/manifest.json.

Core — src/MacSwitcher.Core (net462;net10.0); Win32/UIA — src/MacSwitcher.Windows/Native,Automation,Runtime; WinForms — UI; локальное сохранение — Storage. Core.Tests работает на net10.0; Windows.exe target net462, AnyCPU.

Адресная запись в проверенный HWND Edit/RichEdit через native range writer с подтверждением выделения либо проверяемый UIA plain-value writer. Глобальный SendInput и delete-first fallback запрещены. Неизвестный результат не повторять. Буквы пользователя не подавлять и не писать в историю. Секреты/пароли не читать. Source/field/runtimeID/caret/revision проверять до записи и read-back. Текст только bounded RAM, explicit recovery/import/export local.

asInvoker/uiAccess=false, никаких скрытых admin/services/security bypass. Не писать в пользовательские документы в CI; все runtime-проверки только в собственном synthetic fixture процессе. Не менять macOS исходники/version.json/appcast и установленное приложение.

Проверки будут зафиксированы в windows/scripts и GitHub Windows workflow_dispatch. Runtime/installer evidence отделять от physical Win7/8.1/10/11/ARM и third-party fields. Новый код/fixtures — только в windows/. Generated data/builds игнорируются.
