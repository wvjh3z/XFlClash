#pragma once
#include <gtk/gtk.h>
#include <cstdint>

inline bool xboard_focus_borrowed_window(int64_t handle) {
  // Compare against the live top-level registry before dereferencing a pointer.
  const auto address = static_cast<uintptr_t>(handle);
  GList* windows = gtk_window_list_toplevels();
  GtkWindow* found = nullptr;
  for (GList* node = windows; node; node = node->next) {
    if (reinterpret_cast<uintptr_t>(node->data) == address) {
      found = GTK_WINDOW(node->data);
      break;
    }
  }
  g_list_free(windows);
  if (!found) return false;
  gtk_window_deiconify(found);
  gtk_window_present(found);
  return true;
}
