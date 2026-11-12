package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/huh"
)

const targetUser = "charlie"

// 救援用的一次性腳本：平常 charlie 完全沒有密碼（只能用 SSH 金鑰登入），這是
// 刻意的設計；但如果 WireGuard 或 SSH 本身掛了，連 ESXi console 都進不去，因為
// console 登入需要密碼，而 charlie 跟 root 都沒有密碼。這支程式讓使用者在還能
// SSH 進去的時候，自己決定要不要開這條退路：互動問一個密碼、把 charlie 加進
// sudo group（charlie 其實已經有 /etc/sudoers.d/charlie 給的 NOPASSWD sudo，
// 這裡額外加 sudo group 純粹是因為使用者要求「升級成 sudo group」，兩者不衝突）、
// 設好密碼，然後自己刪除自己——避免留著一支「隨便一個碰到這台機器的人都能直接
// 加密碼、拿 sudo」的程式在機器上。
func main() {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "錯誤：請用 sudo 執行這支程式（例如：sudo ~/bootstrap-sudo）")
		os.Exit(1)
	}

	var password string
	var confirm string

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewNote().
				Title("幫 " + targetUser + " 開一條救援退路").
				Description(targetUser + " 平常只能用 SSH 金鑰登入、沒有密碼。這裡幫它設一個密碼、加進 sudo group，\n這樣 WireGuard／SSH 掛掉的時候，還能從 ESXi 的 VM console 直接登入救援。"),
			huh.NewInput().
				Title("設定密碼").
				EchoMode(huh.EchoModePassword).
				Value(&password).
				Validate(func(s string) error {
					if len(s) < 8 {
						return fmt.Errorf("密碼至少要 8 個字元")
					}
					return nil
				}),
			huh.NewInput().
				Title("再輸入一次確認").
				EchoMode(huh.EchoModePassword).
				Value(&confirm),
		),
	)

	if err := form.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
		os.Exit(1)
	}

	if password != confirm {
		fmt.Fprintln(os.Stderr, "錯誤：兩次輸入的密碼不一樣，沒有做任何變更")
		os.Exit(1)
	}

	if err := runCommand("usermod", "-aG", "sudo", targetUser); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：把 %s 加進 sudo group 失敗：%v\n", targetUser, err)
		os.Exit(1)
	}

	if err := setPassword(targetUser, password); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：設定密碼失敗：%v\n", err)
		os.Exit(1)
	}

	fmt.Printf("%s 已經加進 sudo group、也設好密碼了。WireGuard／SSH 都連不上的時候，\n", targetUser)
	fmt.Println("可以直接從 ESXi 的 VM console 登入救援。")

	selfDelete()
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func setPassword(user, password string) error {
	cmd := exec.Command("chpasswd")
	cmd.Stdin = strings.NewReader(user + ":" + password + "\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// 跑完就自刪——這是一次性救援腳本，不是常駐工具，留著只會變成一個不用密碼
// 就能直接幫任何人加密碼、加 sudo 的後門。在 Linux 上刪除自己正在執行的
// 檔案是安全的：inode 在程序結束前都還在，只是從目錄裡拿掉名字而已。
func selfDelete() {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "警告：找不到自己的執行檔路徑，沒有自動刪除：%v\n", err)
		return
	}
	if err := os.Remove(exe); err != nil {
		fmt.Fprintf(os.Stderr, "警告：自我刪除失敗，手動刪掉 %s 比較安全：%v\n", exe, err)
	}
}
