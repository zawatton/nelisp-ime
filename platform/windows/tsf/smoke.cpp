#define NOMINMAX
#include <windows.h>
#include <msctf.h>
#include <initguid.h>
#include <string>

DEFINE_GUID(CLSID_NelispImeSmoke, 0xd699a42d, 0x88e9, 0x4e0c, 0xb1, 0xbf,
            0xef, 0x8f, 0x49, 0x83, 0x3a, 0x71);

using GetClassObject = HRESULT(__stdcall *)(REFCLSID, REFIID, void **);

int wmain(int argc, wchar_t **argv) {
  if (argc != 2) return 2;
  HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  HMODULE module = LoadLibraryW(argv[1]);
  if (!module) return 3;
  auto getClass = reinterpret_cast<GetClassObject>(
      GetProcAddress(module, "DllGetClassObject"));
  if (!getClass) return 4;
  IClassFactory *factory = nullptr;
  HRESULT result = getClass(CLSID_NelispImeSmoke, IID_IClassFactory,
                            reinterpret_cast<void **>(&factory));
  if (FAILED(result) || !factory) return 5;
  ITfTextInputProcessor *service = nullptr;
  result = factory->CreateInstance(nullptr, IID_ITfTextInputProcessor,
                                   reinterpret_cast<void **>(&service));
  if (service) service->Release();
  factory->Release();
  FreeLibrary(module);
  if (SUCCEEDED(initialized)) CoUninitialize();
  return SUCCEEDED(result) ? 0 : 6;
}
