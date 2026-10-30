# 键盘 (JianPan)

照 **Laetus 逆向结论**实现的键盘美化插件。

## 实现原理（Laetus 逆向证据，iOS 17.2 头文件级确认）

只需 2 个 hook 点：

1. **`UIKBSplitImageView setImage:cachedWidth:keyplane:`** —— 键盘背景贴图统一入口
   （`UIKBBackgroundView`（键盘背景视图本体）继承自它；替换传入的 image 即换背景）
2. **`UIKeyboardLayoutStar _didChangeKeyplaneWithContext:`** —— keyplane 切换跟踪
   （`keyplaneName` 是公开 property，直接读当前面名）

### keyplane → 主题键映射（Laetus keyplaneNameToKey: 0x14774 逆向）

| keyplane 名 | 主题键 |
|---|---|
| small-letters / capital-letters | KeyboardMainBG |
| numbers-and-punctuation(-alternative) | KeyboardNumbersBG |
| emoji-keyboard | KeyboardEmojiBG |
| *-pad | KeyboardNumberPadBG |
| autofill | KeyboardAutoFillBG |
| picker | KeyboardPickerBG |
| dictation | KeyboardDictationBG |
| （默认） | KeyboardMainBG |

### 图片查找（Laetus imagePathWithName 0x14310 逆向）

`键名(-方向)(-屏高)(@3x/@2x).png` 逐级剥离降级 + 926h→896h / 844h→812h 屏高映射兜底。

## 主题目录

```
/var/jb/Library/JianPan/Themes/我的主题/
  KeyboardMainBG-Portrait-932h@3x.png
  KeyboardNumbersBG-Portrait-932h@3x.png
  ...
```

设置 → 键盘 → 选择主题（未选时自动用第一个主题）→ 重新弹出键盘生效。

## 构建

GitHub Actions（macos-15 + roothide theos + iPhoneOS16.5 SDK），产物 arm64e roothide deb。

## 作者

Ning
