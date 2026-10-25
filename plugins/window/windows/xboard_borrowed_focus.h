#pragma once
#include <windows.h>
#include <cstdint>

// Borrow only: never destroy the window or replace its procedure/delegate.
inline bool XboardFocusBorrowedWindow(int64_t address) {
  const auto hwnd = reinterpret_cast<HWND>(address);
  DWORD owner = 0;
  if (!hwnd || !IsWindow(hwnd) || !GetWindowThreadProcessId(hwnd, &owner) ||
      owner != GetCurrentProcessId()) return false;
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  // Windows may deny foreground stealing; the live window is still restored.
  SetForegroundWindow(hwnd);
  return true;
}
