// Browser preview uses origin-scoped settings, independent of the RPi file.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

String? readSettings() => html.window.localStorage['simplelay-kiosk-settings'];
void writeSettings(String value) {
  html.window.localStorage['simplelay-kiosk-settings'] = value;
}
