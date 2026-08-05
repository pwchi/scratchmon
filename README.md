# scratchmon

在使用者 SSH 登入 HPC 叢集時，自動偵測 `/scratch`（或其他任意暫存空間）的整體使用率，超過門檻時顯示醒目的動態警告；若該檔案系統是 Lustre，還會額外顯示登入者自己的個人用量。

```
────────────────────────────────────────────────────────────────
 !!  WARNING: SCRATCH SPACE ALMOST FULL  !!

Mount point : /scratch
Usage       : 87%  (used 187G / total 200G)
Action      : I/O performance may degrade once /scratch usage exceeds 80%. Please clean up your personal files in /scratch ASAP.
────────────────────────────────────────────────────────────────
Your usage on /scratch (alice): 45G used  (22.50% of total capacity)
```

## 功能特色

- **登入時自動檢查**：以 `/etc/profile.d/` 機制，在使用者 SSH 登入互動式 shell 時自動執行，不需要使用者做任何事。
- **不會拖慢登入**：所有檔案系統查詢（`df`、`mountpoint`、`lfs quota`）都用 `timeout` 保護，檔案系統異常時最多延遲數秒後自動放棄顯示，不會卡住登入流程。
- **整體使用率警告**：超過設定門檻時顯示醒目的動態進度條動畫 + 警告訊息。
- **個人用量顯示**（選用）：若掛載點是 Lustre 檔案系統，額外用 `lfs quota` 顯示登入者自己的用量，以及佔整體容量的百分比。兩個功能互相獨立——整體沒超標，個人用量一樣會顯示；個人用量查詢失敗，整體警告不受影響。
- **掛載點路徑不寫死**：透過設定檔指定，或自動偵測路徑中含 `scratch` 字樣的掛載點，儲存系統更換底層裝置也不用改程式。
- **設定檔安全檢查**：載入設定檔前會驗證檔案 owner 與權限，避免設定檔被竄改後在其他使用者的 shell 中被動執行任意指令。
- **內建 `--demo` 模式**：不需要真的觸發使用率超標、不需要 root 權限，就能直接看到完整效果，方便部署前測試。

## 系統需求

開發與測試環境為 **Rocky Linux 8.10**，理論上適用於任何有 bash 4+ 的現代 Linux 發行版。

| 用途 | 套件 | 備註 |
|---|---|---|
| 核心功能 | `coreutils`（`df`、`timeout`、`stat`）、`util-linux`（`mountpoint`、`findmnt`、`logger`）、`gawk`、`grep`、`sed` | 標準安裝都會有，通常不需要額外安裝 |
| 個人用量顯示 | Lustre client（`lfs`） | 非 Lustre 檔案系統會自動略過此功能，不影響其餘部分 |
| 動態分隔線寬度 | `ncurses-utils`（`tput`） | Minimal 安裝可能沒有，缺少時自動 fallback 為固定寬度，不影響其他功能 |

## 安裝

```bash
git clone <此 repo 網址>
cd scratchmon

# 1. 部署設定檔
sudo cp scratchmon.conf /etc/scratchmon.conf
sudo chown root:root /etc/scratchmon.conf
sudo chmod 644 /etc/scratchmon.conf

# 2. 部署登入腳本
sudo cp zz_scratchmon.sh /etc/profile.d/
sudo chown root:root /etc/profile.d/zz_scratchmon.sh
sudo chmod 755 /etc/profile.d/zz_scratchmon.sh

# 3. 編輯設定檔，至少確認 SCRATCH_MOUNT 是正確的掛載點路徑
sudo vim /etc/scratchmon.conf
```

之後重新 SSH 登入即可看到效果。

> **權限要求務必遵守**：設定檔內容會被當成 bash 指令 `source` 執行。若設定檔可被 root 以外的人寫入，任何使用者都能植入指令，並在「每一個登入使用者」的 shell 裡、以該使用者的權限被執行——等同開了一個後門。腳本本身在載入前會檢查 owner 與權限，權限不符會拒絕載入並記錄到 syslog，但這只是最後一道防線，正確設定檔案權限仍是管理者的責任。

## 部署前測試

不需要 root 權限、不需要真的有 scratch 掛載點、不需要觸發真實的使用率超標，就能直接看到完整效果：

```bash
./zz_scratchmon.sh --demo
```

也可以指定自訂設定檔測試不同參數組合（例如關閉動畫效果）：

```bash
./zz_scratchmon.sh --demo --conf ./my_test.conf
```

完整參數說明：

```bash
./zz_scratchmon.sh --help
```

| 參數 | 說明 |
|---|---|
| `--demo` | 用固定的測試資料顯示效果，不需要互動式登入 shell，也不需要真的觸發使用率超標。`SCRATCH_MOUNT`／`THRESHOLD`／`DF_TIMEOUT` 會被強制覆寫以保證一定觸發，`ANIMATION` 等顯示效果類參數則沿用設定檔實際值。 |
| `--conf PATH`／`--conf=PATH` | 使用指定的設定檔，取代預設的 `/etc/scratchmon.conf`。常搭配 `--demo` 在本機測試，不需要 root 權限，也不需要通過正式環境的檔案權限安全檢查（該檢查只套用在預設路徑）。 |
| `-h`／`--help` | 顯示使用說明並結束。 |

## 設定檔 (`/etc/scratchmon.conf`)

| 參數 | 預設值 | 說明 |
|---|---|---|
| `SCRATCH_MOUNT` | `/scratch` | 要監控的掛載點路徑。留空 `""` 時會自動尋找路徑中含 `scratch` 字樣的掛載點（僅供測試/救急，正式環境建議明確指定）。 |
| `THRESHOLD` | `80` | 觸發整體使用率警告的門檻（百分比整數，0–100）。 |
| `DF_TIMEOUT` | `3` | `df`／`mountpoint` 查詢逾時秒數。這是登入當下即時查詢，逾時秒數就是檔案系統異常時使用者登入最多會被拖慢的秒數，建議設短（2–3 秒）。 |
| `ANIMATION` | `1` | 是否啟用登入時的動態進度條效果（`1`=啟用，`0`=停用）。 |
| `LOG_FAILURES` | `1` | 查詢失敗或逾時時，是否記錄到 syslog（`1`=啟用，`0`=停用），方便管理者事後追查 scratch 檔案系統是否常態性異常。 |
| `SHOW_USER_QUOTA` | `1` | 是否顯示登入使用者自己在 scratch 上的用量（需要 Lustre + `lfs` 指令）。非 Lustre 或找不到 `lfs` 時會自動略過，不顯示錯誤訊息。 |
| `LFS_TIMEOUT` | `5` | `lfs quota` 查詢逾時秒數，獨立於 `DF_TIMEOUT`，因為在某些叢集上可能比一般 `df` 慢。 |

設定檔本身不需要額外標頭，直接用 shell 變數賦值語法即可，範例請見 repo 內的 `scratchmon.conf`。

## 運作方式

1. 使用者 SSH 登入，`/etc/profile.d/zz_scratchmon.sh` 被系統自動 `source` 執行。
2. 檔名以 `zz_` 開頭，確保排在同目錄下其他 profile.d 腳本之後執行，此時 `PATH` 等環境變數應已由系統完整設定。
3. 只在「互動式登入 shell + 有終端機」時顯示，避免 `scp`/`rsync` 等非互動連線被干擾。
4. 讀取設定檔（先驗證 owner/權限），任何數值型參數不合法都會退回安全預設值並記錄到 syslog，不會讓使用者看到 bash 錯誤訊息。
5. 用 `timeout` 包住 `mountpoint`/`df` 查詢整體使用率；若為 Lustre，另外查詢個人配額。任一查詢失敗都會安靜跳過（並視設定選擇性記錄 syslog），不影響登入。
6. 兩個顯示區塊（整體警告 / 個人用量）各自獨立判斷是否顯示。

## 已知限制

- `/etc/profile.d/*.sh` 只對會 source `/etc/profile` 的 shell（bash/sh/zsh 等）生效；若叢集上有使用者用 `tcsh`/`csh` 登入，需要額外撰寫對應的 `.csh` 版本。
- `SCRATCH_MOUNT` 自動偵測只是盡量猜測的 fallback，正式環境務必在設定檔明確指定，避免猜到非預期的掛載點。
- 個人用量顯示僅支援 Lustre（`lfs quota`），其他網路檔案系統（BeeGFS、GPFS...）目前不支援，會自動略過此區塊。
- `df`/`lfs quota` 查詢是登入當下即時執行，若檔案系統本身異常，使用者登入仍會被拖慢最多 `DF_TIMEOUT`（+ `LFS_TIMEOUT`，若有觸發）秒。

## 授權

本專案目前**尚未附加授權條款（LICENSE）**，授權歸屬（個人／單位）與條款仍在確認中。在補上 LICENSE 之前：

- 程式碼公開可見、可下載參考，但**尚未取得明確的重製/修改/散布授權**。
- 內部同仁請依單位規範使用；若要在單位外部署或散布，請先與作者確認目前的授權狀態。

授權條款確認後會另行補上，屆時會在此更新。

## 貢獻

歡迎回報問題或提交 PR。修改 `zz_scratchmon.sh` 前，建議先用 `bash -n` 做語法檢查，並用 `--demo` 模式驗證顯示效果。
