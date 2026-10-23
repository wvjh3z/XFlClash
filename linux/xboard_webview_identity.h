#pragma once
#include <webkit2/webkit2.h>
#ifndef XBOARD_WEBVIEW_APP_ID
#define XBOARD_WEBVIEW_APP_ID "com.follow.clash"
#endif

inline gchar* xboard_webview_data_directory() {
  return g_build_filename(g_get_user_data_dir(), XBOARD_WEBVIEW_APP_ID, "crisp-webkit", nullptr);
}
inline gchar* xboard_webview_cache_directory() {
  return g_build_filename(g_get_user_cache_dir(), XBOARD_WEBVIEW_APP_ID, "crisp-webkit", nullptr);
}
inline WebKitWebContext* xboard_webview_context() {
  // Intentional process lifetime: no WebKit destruction during DSO teardown.
  static WebKitWebContext* context = [] {
    if (g_strcmp0(XBOARD_WEBVIEW_APP_ID, "com.follow.clash") == 0)
      return webkit_web_context_get_default();
    gchar* data = xboard_webview_data_directory();
    gchar* cache = xboard_webview_cache_directory();
    auto* manager = webkit_website_data_manager_new(
        "base-data-directory", data, "base-cache-directory", cache, nullptr);
    g_free(data);
    g_free(cache);
    auto* owned = webkit_web_context_new_with_website_data_manager(manager);
    g_object_unref(manager);
    return owned;
  }();
  return context;
}
inline GtkWidget* xboard_web_view_new() {
  return webkit_web_view_new_with_context(xboard_webview_context());
}
// Both the window constructor and the plugin's clearAll view use this context.
#define webkit_web_view_new xboard_web_view_new
