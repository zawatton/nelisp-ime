#include "nelisp_ime_client.hpp"
#include <cstdio>
#include <iostream>

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  try {
    std::remove(argv[3]);
    std::string learned;
    {
      nelisp_ime::Client client(argv[1], argv[2]);
      client.start(); client.openSession("common-smoke", "romaji");
      nelisp_ime::Snapshot snapshot;
      for (const char *key : {"k", "a", "n", "j", "i"}) snapshot = client.feedKey("common-smoke", key);
      if (snapshot.reading != "かんじ" || snapshot.preedit != "漢字") return 3;
      if (snapshot.candidates.size() < 2) return 4;
      snapshot = client.feedOperation("common-smoke", "select-candidate", 1);
      learned = snapshot.preedit;
      snapshot = client.feedOperation("common-smoke", "commit");
      if (snapshot.commit != learned) return 5;
      client.saveLearning(argv[3]);
      client.openSession("phrase-smoke", "romaji");
      for (char key : std::string("kyouhaiitenkidesu"))
        snapshot = client.feedKey("phrase-smoke", std::string(1, key));
      if (snapshot.preedit != "今日はいい天気です") return 7;
    }
    {
      nelisp_ime::Client client(argv[1], argv[2]);
      client.start(); client.loadLearning(argv[3]);
      client.openSession("common-smoke-loaded", "romaji");
      nelisp_ime::Snapshot snapshot;
      for (const char *key : {"k", "a", "n", "j", "i"}) snapshot = client.feedKey("common-smoke-loaded", key);
      if (snapshot.preedit != learned) return 6;
    }
    std::remove(argv[3]);
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
  return 0;
}
