#define NOMINMAX
#include <windows.h>
#include <msctf.h>
#include <initguid.h>
#include "nelisp_ime_client.hpp"
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>

// {D699A42D-88E9-4E0C-B1BF-EF8F49833A71}
DEFINE_GUID(CLSID_NelispIme, 0xd699a42d, 0x88e9, 0x4e0c, 0xb1, 0xbf, 0xef, 0x8f, 0x49, 0x83, 0x3a, 0x71);
// {BB0DB64E-3B62-4829-8072-48A9F27F7679}
DEFINE_GUID(GUID_NelispProfile, 0xbb0db64e, 0x3b62, 0x4829, 0x80, 0x72, 0x48, 0xa9, 0xf2, 0x7f, 0x76, 0x79);

namespace {
HINSTANCE moduleHandle;
LONG objectCount;
LONG serverLocks;

std::string envOr(const char *name, const char *fallback) {
#ifdef _MSC_VER
  char *value = nullptr;
  size_t length = 0;
  if (_dupenv_s(&value, &length, name) != 0 || !value) return fallback;
  std::string result = *value ? value : fallback;
  std::free(value);
  return result;
#else
  const char *value = std::getenv(name);
  return value && *value ? value : fallback;
#endif
}
std::wstring utf16(const std::string &value) {
  if (value.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), size);
  return out;
}
std::string utf8(const std::wstring &value) {
  if (value.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                 nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}
std::filesystem::path moduleDirectory() {
  std::wstring path(32768, L'\0');
  DWORD size = GetModuleFileNameW(moduleHandle, path.data(), static_cast<DWORD>(path.size()));
  path.resize(size);
  return std::filesystem::path(path).parent_path();
}
std::wstring guidString(REFGUID guid) {
  wchar_t text[40];
  StringFromGUID2(guid, text, 40);
  return text;
}

class TextService;
class EditSession final : public ITfEditSession {
public:
  EditSession(TextService *service, ITfContext *context, nelisp_ime::Snapshot snapshot);
  ~EditSession();
  STDMETHODIMP QueryInterface(REFIID, void **) override;
  STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
  STDMETHODIMP_(ULONG) Release() override {
    ULONG refs = static_cast<ULONG>(InterlockedDecrement(&refs_));
    if (!refs) delete this;
    return refs;
  }
  STDMETHODIMP DoEditSession(TfEditCookie cookie) override;
private:
  LONG refs_ = 1;
  TextService *service_;
  ITfContext *context_;
  nelisp_ime::Snapshot snapshot_;
};

class TextService final : public ITfTextInputProcessor,
                          public ITfKeyEventSink,
                          public ITfCompositionSink {
public:
  TextService() { InterlockedIncrement(&objectCount); }
  ~TextService() {
    deactivate();
    InterlockedDecrement(&objectCount);
  }
  STDMETHODIMP QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_INVALIDARG;
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_ITfTextInputProcessor)
      *out = static_cast<ITfTextInputProcessor *>(this);
    else if (iid == IID_ITfKeyEventSink) *out = static_cast<ITfKeyEventSink *>(this);
    else if (iid == IID_ITfCompositionSink) *out = static_cast<ITfCompositionSink *>(this);
    if (!*out) return E_NOINTERFACE;
    AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
  STDMETHODIMP_(ULONG) Release() override {
    ULONG refs = static_cast<ULONG>(InterlockedDecrement(&refs_));
    if (!refs) delete this;
    return refs;
  }
  STDMETHODIMP Activate(ITfThreadMgr *manager, TfClientId id) override {
    manager_ = manager; manager_->AddRef(); clientId_ = id;
    ITfKeystrokeMgr *keys = nullptr;
    HRESULT result = manager_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keys));
    if (SUCCEEDED(result)) { result = keys->AdviseKeyEventSink(id, this, TRUE); keys->Release(); }
    try {
      std::filesystem::path base = moduleDirectory();
      client_ = std::make_unique<nelisp_ime::Client>(
          envOr("NELISP_IME_RUNTIME", utf8((base / L"nelisp.exe").wstring()).c_str()),
          envOr("NELISP_IME_ROOT", utf8((base.parent_path() / L"nelisp-root").wstring()).c_str()));
      client_->start();
      learningFile_ = envOr("LOCALAPPDATA", ".") + "/NeLispIME/learning.json";
      client_->loadLearning(learningFile_);
      sessionId_ = "tsf:" + std::to_string(GetCurrentThreadId());
      client_->openSession(sessionId_, "romaji");
    } catch (...) { return E_FAIL; }
    return result;
  }
  STDMETHODIMP Deactivate() override { deactivate(); return S_OK; }
  STDMETHODIMP OnSetFocus(BOOL) override { return S_OK; }
  STDMETHODIMP OnTestKeyDown(ITfContext *, WPARAM wparam, LPARAM, BOOL *eaten) override {
    *eaten = handles(wparam); return S_OK;
  }
  STDMETHODIMP OnTestKeyUp(ITfContext *, WPARAM, LPARAM, BOOL *eaten) override {
    *eaten = FALSE; return S_OK;
  }
  STDMETHODIMP OnKeyUp(ITfContext *, WPARAM, LPARAM, BOOL *eaten) override {
    *eaten = FALSE; return S_OK;
  }
  STDMETHODIMP OnPreservedKey(ITfContext *, REFGUID, BOOL *eaten) override {
    *eaten = FALSE; return S_OK;
  }
  STDMETHODIMP OnKeyDown(ITfContext *context, WPARAM key, LPARAM lparam, BOOL *eaten) override {
    *eaten = FALSE;
    if (!client_ || !handles(key)) return S_OK;
    try {
      nelisp_ime::Snapshot snapshot;
      if (key >= 'A' && key <= 'Z')
        snapshot = client_->feedKey(sessionId_, std::string(1, static_cast<char>(key - 'A' + 'a')));
      else if (key == VK_OEM_7) snapshot = client_->feedKey(sessionId_, "'");
      else if (key == VK_BACK) snapshot = client_->feedOperation(sessionId_, "backspace");
      else if (key == VK_ESCAPE) snapshot = client_->feedOperation(sessionId_, "cancel");
      else if (key == VK_RETURN) snapshot = client_->feedOperation(sessionId_, "commit");
      else if (key == VK_SPACE && !last_.candidates.empty()) {
        int next = (last_.candidateIndex + 1) % static_cast<int>(last_.candidates.size());
        snapshot = client_->feedOperation(sessionId_, "select-candidate", next);
      } else if (key == VK_LEFT && last_.activeSegment > 0)
        snapshot = client_->feedOperation(sessionId_, "select-segment",
                                          last_.activeSegment - 1);
      else if (key == VK_RIGHT && last_.activeSegment + 1 < last_.segmentCount)
        snapshot = client_->feedOperation(sessionId_, "select-segment",
                                          last_.activeSegment + 1);
      else if (!last_.preedit.empty()) {
        BYTE keyboard[256]{};
        wchar_t characters[8]{};
        if (!GetKeyboardState(keyboard)) return S_OK;
        int count = ToUnicodeEx(static_cast<UINT>(key),
            static_cast<UINT>((lparam >> 16) & 0xff), keyboard, characters, 8,
            0, GetKeyboardLayout(0));
        if (count <= 0) return S_OK;
        snapshot = client_->feedOperation(sessionId_, "commit");
        snapshot.commit += utf8(std::wstring(characters, characters + count));
      } else return S_OK;
      last_ = snapshot;
      if (!snapshot.commit.empty()) client_->saveLearning(learningFile_);
      auto *edit = new EditSession(this, context, std::move(snapshot));
      HRESULT sessionResult = E_FAIL;
      HRESULT result = context->RequestEditSession(clientId_, edit,
          TF_ES_ASYNC | TF_ES_READWRITE, &sessionResult);
      edit->Release();
      *eaten = SUCCEEDED(result);
      return result;
    } catch (...) { return E_FAIL; }
  }
  STDMETHODIMP OnCompositionTerminated(TfEditCookie, ITfComposition *composition) override {
    if (composition_ == composition) { composition_->Release(); composition_ = nullptr; }
    return S_OK;
  }
  HRESULT apply(TfEditCookie cookie, ITfContext *context,
                const nelisp_ime::Snapshot &snapshot) {
    ITfRange *range = nullptr;
    if (composition_) composition_->GetRange(&range);
    if (!range) {
      TF_SELECTION selection{}; ULONG fetched = 0;
      HRESULT result = context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched);
      if (FAILED(result) || !fetched) return result;
      range = selection.range;
    }
    std::wstring text = utf16(snapshot.commit.empty() ? snapshot.preedit : snapshot.commit);
    HRESULT result = range->SetText(cookie, 0, text.data(), static_cast<LONG>(text.size()));
    if (SUCCEEDED(result) && snapshot.commit.empty() && !snapshot.preedit.empty() && !composition_) {
      ITfContextComposition *owner = nullptr;
      if (SUCCEEDED(context->QueryInterface(IID_ITfContextComposition,
                                            reinterpret_cast<void **>(&owner)))) {
        owner->StartComposition(cookie, range, this, &composition_);
        owner->Release();
      }
    }
    if (composition_ && (!snapshot.commit.empty() || snapshot.preedit.empty())) {
      composition_->EndComposition(cookie);
      composition_->Release(); composition_ = nullptr;
    }
    range->Release();
    return result;
  }
private:
  bool handles(WPARAM key) const {
    if ((GetKeyState(VK_CONTROL) & 0x8000) || (GetKeyState(VK_MENU) & 0x8000) ||
        (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000))
      return false;
    if (key >= 'A' && key <= 'Z') return true;
    if (key == VK_OEM_7) return true;
    if (last_.preedit.empty()) return false;
    if (key == VK_BACK || key == VK_ESCAPE || key == VK_RETURN ||
        key == VK_SPACE || key == VK_LEFT || key == VK_RIGHT) return true;
    BYTE keyboard[256]{}; wchar_t text[2]{};
    return GetKeyboardState(keyboard) &&
           ToUnicodeEx(static_cast<UINT>(key), MapVirtualKeyW(static_cast<UINT>(key), MAPVK_VK_TO_VSC),
                       keyboard, text, 2, 0,
                       GetKeyboardLayout(0)) > 0;
  }
  void deactivate() {
    if (manager_) {
      ITfKeystrokeMgr *keys = nullptr;
      if (SUCCEEDED(manager_->QueryInterface(IID_ITfKeystrokeMgr,
                                             reinterpret_cast<void **>(&keys)))) {
        keys->UnadviseKeyEventSink(clientId_); keys->Release();
      }
      manager_->Release(); manager_ = nullptr;
    }
    if (client_) { try { client_->closeSession(sessionId_); } catch (...) {} client_.reset(); }
    if (composition_) { composition_->Release(); composition_ = nullptr; }
  }
  LONG refs_ = 1;
  ITfThreadMgr *manager_ = nullptr;
  TfClientId clientId_ = 0;
  ITfComposition *composition_ = nullptr;
  std::unique_ptr<nelisp_ime::Client> client_;
  std::string sessionId_;
  std::string learningFile_;
  nelisp_ime::Snapshot last_;
};

EditSession::EditSession(TextService *service, ITfContext *context,
                         nelisp_ime::Snapshot snapshot)
    : service_(service), context_(context), snapshot_(std::move(snapshot)) {
  service_->AddRef(); context_->AddRef();
}
EditSession::~EditSession() { context_->Release(); service_->Release(); }
STDMETHODIMP EditSession::QueryInterface(REFIID iid, void **out) {
  if (!out) return E_INVALIDARG;
  *out = nullptr;
  if (iid == IID_IUnknown || iid == IID_ITfEditSession) *out = this;
  if (!*out) return E_NOINTERFACE;
  AddRef(); return S_OK;
}
STDMETHODIMP EditSession::DoEditSession(TfEditCookie cookie) {
  return service_->apply(cookie, context_, snapshot_);
}

class ClassFactory final : public IClassFactory {
public:
  STDMETHODIMP QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_INVALIDARG;
    *out = (iid == IID_IUnknown || iid == IID_IClassFactory) ? this : nullptr;
    if (!*out) return E_NOINTERFACE;
    AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
  STDMETHODIMP_(ULONG) Release() override {
    ULONG refs = static_cast<ULONG>(InterlockedDecrement(&refs_));
    if (!refs) delete this;
    return refs;
  }
  STDMETHODIMP CreateInstance(IUnknown *outer, REFIID iid, void **out) override {
    if (outer) return CLASS_E_NOAGGREGATION;
    auto *service = new TextService;
    HRESULT result = service->QueryInterface(iid, out);
    service->Release(); return result;
  }
  STDMETHODIMP LockServer(BOOL lock) override {
    if (lock) InterlockedIncrement(&serverLocks); else InterlockedDecrement(&serverLocks);
    return S_OK;
  }
private:
  LONG refs_ = 1;
};

HRESULT registerCom(bool install) {
  std::wstring key = L"Software\\Classes\\CLSID\\" + guidString(CLSID_NelispIme);
  if (!install) return RegDeleteTreeW(HKEY_CURRENT_USER, key.c_str()) == ERROR_SUCCESS ? S_OK : S_FALSE;
  wchar_t path[MAX_PATH]; GetModuleFileNameW(moduleHandle, path, MAX_PATH);
  HKEY clsid = nullptr, server = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_WRITE,
                      nullptr, &clsid, nullptr) != ERROR_SUCCESS) return E_FAIL;
  const wchar_t name[] = L"NeLisp Japanese IME";
  RegSetValueExW(clsid, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE *>(name), sizeof(name));
  RegCreateKeyExW(clsid, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &server, nullptr);
  RegSetValueExW(server, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE *>(path),
                 static_cast<DWORD>((wcslen(path) + 1) * sizeof(wchar_t)));
  const wchar_t threading[] = L"Apartment";
  RegSetValueExW(server, L"ThreadingModel", 0, REG_SZ,
                 reinterpret_cast<const BYTE *>(threading), sizeof(threading));
  if (server) RegCloseKey(server);
  RegCloseKey(clsid);
  return S_OK;
}
HRESULT registerProfile(bool install) {
  ITfInputProcessorProfiles *profiles = nullptr;
  HRESULT result = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles,
      reinterpret_cast<void **>(&profiles));
  if (FAILED(result)) return result;
  if (install) {
    result = profiles->Register(CLSID_NelispIme);
    if (SUCCEEDED(result)) {
      const wchar_t label[] = L"NeLisp Japanese";
      result = profiles->AddLanguageProfile(CLSID_NelispIme, MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT),
          GUID_NelispProfile, label, static_cast<ULONG>(wcslen(label)), nullptr, 0, 0);
    }
  } else result = profiles->Unregister(CLSID_NelispIme);
  profiles->Release(); return result;
}
HRESULT registerCategory(bool install) {
  ITfCategoryMgr *categories = nullptr;
  HRESULT result = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
      reinterpret_cast<void **>(&categories));
  if (FAILED(result)) return result;
  result = install
      ? categories->RegisterCategory(CLSID_NelispIme, GUID_TFCAT_TIP_KEYBOARD,
                                     CLSID_NelispIme)
      : categories->UnregisterCategory(CLSID_NelispIme,
                                       GUID_TFCAT_TIP_KEYBOARD,
                                       CLSID_NelispIme);
  categories->Release(); return result;
}
} // namespace

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) { moduleHandle = instance; DisableThreadLibraryCalls(instance); }
  return TRUE;
}
STDAPI DllCanUnloadNow(void) {
  return objectCount == 0 && serverLocks == 0 ? S_OK : S_FALSE;
}
STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, LPVOID *out) {
  if (clsid != CLSID_NelispIme) return CLASS_E_CLASSNOTAVAILABLE;
  auto *factory = new ClassFactory;
  HRESULT result = factory->QueryInterface(iid, out); factory->Release(); return result;
}
STDAPI DllRegisterServer(void) {
  HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  HRESULT result = registerCom(true);
  if (SUCCEEDED(result)) result = registerProfile(true);
  if (SUCCEEDED(result)) result = registerCategory(true);
  if (SUCCEEDED(initialized)) CoUninitialize();
  return result;
}
STDAPI DllUnregisterServer(void) {
  HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  registerCategory(false); registerProfile(false);
  HRESULT result = registerCom(false);
  if (SUCCEEDED(initialized)) CoUninitialize();
  return result;
}
