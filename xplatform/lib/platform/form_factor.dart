import 'dart:io';

enum FormFactor { mobile, desktop }

FormFactor get currentFormFactor {
  if (Platform.isAndroid || Platform.isIOS) return FormFactor.mobile;
  return FormFactor.desktop;
}

bool get isMobile => currentFormFactor == FormFactor.mobile;
bool get isDesktop => currentFormFactor == FormFactor.desktop;
