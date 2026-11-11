# ansible

用 Ansible 在一台「單機 ESXi host(沒有 vCenter)」上,透過全自動 preseed 安裝,建立一台 Debian VM,並且自動產生、分發 SSH 金鑰。之所以不在本機(WSL/容器)上做,是因為本機記憶體不夠跑完整的虛擬機安裝。

## 需要準備什麼

**本機(control node)要先手動裝好 `task`**(跑本專案所有自動化指令的入口)——這個沒辦法靠 `task install` 幫你裝,因為裝它這個動作本身就需要先有 `task`,邏輯上不能自己把自己裝起來:

```
sh -c "$(curl -ssL https://taskfile.dev/install.sh)" -- -d -b /tmp && sudo mv /tmp/task /usr/local/bin/task && task --version
```

裝好 `task` 之後,跑:

```
task install
```

這會幫你裝好剩下所有東西:`ansible-core`、`requirements.yml` 裡列的 collections(`community.vmware`、`community.crypto`、`ansible.posix`)、重新封裝 ISO 用的 `xorriso`、互動式選單用的 [`gum`](https://github.com/charmbracelet/gum)(走 Charm 官方 apt repo 裝),還有解析 `manifest.json` 用的 `jq`。

**另外還需要**:

- 一台開著、可以連到的 ESXi host(單機版,沒有 vCenter 也沒關係,本專案就是設計給這種情境用的)
- 一顆 Debian netinst ISO(放進 `custom/iso/debian/`,檔名要跟 `custom/iso/manifest.json` 裡登記的一致)

## 使用流程

1. `task install` —— 裝好上面提到的工具
2. 把 Debian ISO 放進 `custom/iso/debian/`(檔名對照 `custom/iso/manifest.json`)
3. `task verify-iso` —— 驗證這顆 ISO 是官方未竄改的版本(細節見腳本註解,全程即時向 `debian.org` 官方來源核對,不信任任何本地快取的金鑰)
4. `cp custom/.env.example custom/.env`,照下面的說明把值填好
5. `task build-debian-vm` —— 跑完整流程:產生 SSH 金鑰 → 渲染 preseed.cfg → 重新封裝 ISO → 上傳到 ESXi datastore → 建 VM → 開機 → 等 VM 裝完、SSH 可連

## `custom/.env` 要填什麼

先 `cp custom/.env.example custom/.env`,`.env` 不會進版控,放真實機密沒問題。這組設定是讓 Ansible(`community.vmware` 這些 module)知道要連到哪一台 ESXi、怎麼登入、VM 要建在哪裡。前三項你平常登入 ESXi 網頁管理介面(`https://<ESXi IP>/ui`,官方叫 VMware Host Client)用的就是同一組資訊;後兩項**不是你自己亂取的名字,是要去 ESXi 介面裡「查」出現成的名稱,再填回來**,這正是你問的 datastore 跟 network 怎麼填的來源。

```
ESXI_HOSTNAME=192.168.1.10
ESXI_USERNAME=root
ESXI_PASSWORD=changeme
ESXI_DATASTORE=datastore1
ESXI_NETWORK="VM Network"
ESXI_VALIDATE_CERTS=false
```

- **`ESXI_HOSTNAME`** —— ESXi 主機的 IP 或網域名稱。就是你瀏覽器網址列打的那串位址(不含 `https://`、不含 `/ui`)。
- **`ESXI_USERNAME`** —— 登入 ESXi 網頁介面的帳號。單機版預設最高權限帳號通常就是 `root`。
- **`ESXI_PASSWORD`** —— 登入 ESXi 網頁介面用的密碼。
- **`ESXI_DATASTORE`** —— VM 的虛擬磁碟、上傳的 ISO 要存在哪個儲存空間。
  **怎麼查**:登入 ESXi 網頁介面 → 左側選單點 **Storage** → 右側清單裡「Name」那一欄,就是你要填的值。單機版沒自己額外接硬碟的話,通常就叫 `datastore1`;如果你自己命名過(例如 `SSD-Datastore`),照清單上顯示的打,**大小寫要完全一致**。
- **`ESXI_NETWORK`** —— VM 的網路卡要接到哪一個 portgroup。
  **怎麼查**:登入 ESXi 網頁介面 → 左側選單點 **Networking** → 切到 **Port groups** 分頁 → 「Name」那一欄就是你要填的值。單機版預設通常叫 `VM Network`(中間有空格,所以範例裡用雙引號包起來——這點很重要,`.env` 是被 `source` 讀的,值有空格沒加引號會直接出錯)。
- **`ESXI_VALIDATE_CERTS`** —— 要不要驗證 ESXi 的 TLS 憑證。保持 `false` 就好:ESXi 預設是自簽憑證(瀏覽器登入時跳出「連線不安全」警告的那張憑證),設 `false` 才能讓 Ansible 正常連線,不會因為憑證不是正式 CA 簽發就直接拒絕連線。

填完之後,`custom/.env` 應該長得跟上面範例結構一樣,只是數值換成你自己 ESXi 的真實資訊。
