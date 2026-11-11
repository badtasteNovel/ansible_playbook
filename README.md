# ansible

用 Ansible 在一台「單機 ESXi host(沒有 vCenter)」上,透過全自動 preseed 安裝,建立一台 Debian VM,並且自動產生、分發 SSH 金鑰。之所以不在本機(WSL/容器)上做,是因為本機記憶體不夠跑完整的虛擬機安裝。

這個專案刻意**不透過任何 vSphere/ESXi API**(不裝 `pyvmomi`、不用 `community.vmware`)——自動化的部分只做到「把 ISO、`.vmx`、SSH 金鑰都產生好並上傳到 datastore」,接下來「註冊這台 VM、按開機」刻意留給你自己在 ESXi 的 Host Client 網頁介面上手動做,原因見 git log 裡的討論(簡單說:之前那條 API 依賴鏈一直踩到各種版本相容性問題,直接用 SSH + `scp` + ESXi 自己的本地工具更穩)。

## 需要準備什麼

**本機(control node)要先手動裝好 `task`**(跑本專案所有自動化指令的入口)——這個沒辦法靠 `task install` 幫你裝,因為裝它這個動作本身就需要先有 `task`,邏輯上不能自己把自己裝起來:

```
sh -c "$(curl -ssL https://taskfile.dev/install.sh)" -- -d -b /tmp && sudo mv /tmp/task /usr/local/bin/task && task --version
```

裝好 `task` 之後,跑:

```
task install
```

這會幫你裝好剩下所有東西:`ansible-core`、`requirements.yml` 裡列的 collections(`community.crypto`、`ansible.posix`)、重新封裝 ISO 用的 `xorriso`、互動式選單用的 [`gum`](https://github.com/charmbracelet/gum)(走 Charm 官方 apt repo 裝)、解析 `manifest.json` 用的 `jq`,還有讓 build 流程可以非互動 SSH 進 ESXi 的 `sshpass`。

**另外還需要**:

- 一台開著、可以連到的 ESXi host(單機版,沒有 vCenter 也沒關係,本專案就是設計給這種情境用的)
- 一顆 Debian netinst ISO(放進 `custom/iso/debian/`,檔名要跟 `custom/iso/manifest.json` 裡登記的一致)

## 使用流程

1. `task install` —— 裝好上面提到的工具
2. 把 Debian ISO 放進 `custom/iso/debian/`(檔名對照 `custom/iso/manifest.json`)
3. `task verify-iso` —— 驗證這顆 ISO 是官方未竄改的版本(細節見腳本註解,全程即時向 `debian.org` 官方來源核對,不信任任何本地快取的金鑰)
4. `cp custom/.env.example custom/.env`,照下面的說明把值填好
5. `task build:debian` —— 產生 client/host 兩組 SSH 金鑰 → 渲染 preseed.cfg → 重新封裝 ISO → 渲染 `.vmx` → SSH 上傳 ISO、`.vmx` 到 datastore、用 `vmkfstools` 建虛擬磁碟。跑完會印出接下來要手動做的事:
   1. 登入 Host Client,瀏覽 datastore 找到那個 `.vmx`,**Register VM**
   2. 手動 **Power On**(preseed 會全自動跑完安裝,不用再管它)
   3. 裝完之後自己查一下 VM 的 IP(它走 DHCP,IP 不是固定的)
   4. 把輸出訊息裡那行 `<IP> ssh-ed25519 ...` 填上實際 IP,貼進 `custom/keys/known_hosts`——host key 是我們自己預先產生、裝機時用 `late_command` 寫進去的,不是 VM 自己隨機生成的,所以裝機前就已經知道 fingerprint,不需要再對 VM 做 `ssh-keyscan`

## `custom/.env` 要填什麼

先 `cp custom/.env.example custom/.env`,`.env` 不會進版控,放真實機密沒問題。這組設定是讓 Taskfile/Ansible 知道要 SSH 進哪一台虛擬化主機、怎麼登入、檔案要放在哪個儲存空間——**不透過任何 vSphere API,純粹 SSH + `scp` + 本地檔案系統工具**,所以命名刻意不綁 ESXi,以後要換別的平台也不用改變數名稱。前三項你平常登入 ESXi 網頁管理介面(`https://<IP>/ui`,官方叫 VMware Host Client)用的就是同一組資訊;後兩項**不是你自己亂取的名字,是要去 ESXi 介面裡「查」出現成的名稱,再填回來**。

```
HYPERVISOR_HOSTNAME=192.168.1.10
HYPERVISOR_USERNAME=root
HYPERVISOR_PASSWORD=changeme
HYPERVISOR_DATASTORE=datastore1
HYPERVISOR_NETWORK='VM Network'
```

- **`HYPERVISOR_HOSTNAME`** —— 主機的 IP 或網域名稱。就是你瀏覽器網址列打的那串位址(不含 `https://`、不含 `/ui`),也是拿來 SSH 登入用的位址。
- **`HYPERVISOR_USERNAME`** —— 登入帳號。ESXi 單機版預設最高權限帳號通常就是 `root`。
- **`HYPERVISOR_PASSWORD`** —— 登入密碼。
- **`HYPERVISOR_DATASTORE`** —— VM 的虛擬磁碟、上傳的 ISO 要存在哪個儲存空間。
  **怎麼查**:登入 ESXi 網頁介面 → 左側選單點 **Storage** → 右側清單裡「Name」那一欄,就是你要填的值。單機版沒自己額外接硬碟的話,通常就叫 `datastore1`;如果你自己命名過(例如 `SSD-Datastore`),照清單上顯示的打,**大小寫要完全一致**。
- **`HYPERVISOR_NETWORK`** —— VM 的網路卡要接到哪一個 portgroup。
  **怎麼查**:登入 ESXi 網頁介面 → 左側選單點 **Networking** → 切到 **Port groups** 分頁 → 「Name」那一欄就是你要填的值。單機版預設通常叫 `VM Network`(中間有空格,所以範例裡加了引號——這點很重要,`.env` 是被 `source` 讀的,值有空格沒加引號會直接出錯)。

填完之後,`custom/.env` 應該長得跟上面範例結構一樣,只是數值換成你自己 ESXi 的真實資訊。
