## 改了什么

<!-- 一句话说清楚这个 PR 做了什么 -->

## 为什么

<!-- 解决的问题 / 关联的 issue，例如 Closes #12 -->

## 怎么验证的

- [ ] `make test` 通过
- [ ] 本地 `./run.sh` 肉眼确认过
- [ ] 涉及界面改动时，已提交 `docs/` 的更新（`make screenshots`，用合成数据）

## 自查

- [ ] 没有引入第三方依赖
- [ ] 新增的文件读写仍然是**只读**的（不写 WorkBuddy 库和 `~/.claude`）
- [ ] 如果改了底栏按钮或行布局，`UIState.hitTest` 的命中区间同步改了
- [ ] 如果改了 `UIState` 里的布局常量，`scripts/smoke-test.sh` 里的期望尺寸同步改了
- [ ] 提交信息符合 Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` …）
- [ ] 同意本次贡献以 [MIT](LICENSE) 协议授权（与项目当前许可一致）

## 截图 / 录屏

<!-- 有界面改动的话放一张，纯逻辑改动可删掉这一节 -->
