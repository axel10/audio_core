//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <dart_chromaprint/dart_chromaprint_plugin_c_api.h>
#include <desktop_drop/desktop_drop_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  DartChromaprintPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DartChromaprintPluginCApi"));
  DesktopDropPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopDropPlugin"));
}
