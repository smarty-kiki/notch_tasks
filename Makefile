.PHONY: help build universal debug run package test preview screenshots icons notes tag clean

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## build       构建到 dist/NotchTasks.app（本机架构）
build:
	./build.sh

## universal   构建通用二进制（arm64 + x86_64）
universal:
	./build.sh --clean --universal

## debug       不优化、带调试符号
debug:
	./build.sh --clean --debug

## run         构建并启动
run:
	./run.sh

## package     打发布包 → dist/NotchTasks-<版本>-macos-<架构>.zip
package:
	./package.sh

## test        冒烟测试（不需要 GUI，也不需要本机数据）
test: build
	./scripts/smoke-test.sh

## preview     用合成数据渲染一遍界面图到 /tmp（只看，不动 docs）
preview: build
	./build/NotchTasks --preview /tmp/notchtasks-preview --demo

## screenshots 重新生成 docs/ 下的截图（合成数据，可安全公开）
screenshots: build
	./scripts/make-screenshots.sh

## icons       重新生成 App 图标（改完 tools/make-icon.swift 后跑）
icons:
	swift tools/make-icon.swift

## notes       打印某个版本的 release notes（默认取 VERSION），例如 make notes V=1.0.0
notes:
	@./scripts/release-notes.sh $(V)

## tag         给当前 VERSION 打标签（不推送），例如 VERSION 是 1.0.0 → tag v1.0.0
tag:
	@git tag -a "v$$(tr -d '[:space:]' < VERSION)" -m "任务坞 v$$(tr -d '[:space:]' < VERSION)" && \
	 echo "已打标签 v$$(tr -d '[:space:]' < VERSION)，推送：git push origin v$$(tr -d '[:space:]' < VERSION)"

## clean       清掉构建产物
clean:
	rm -rf build dist
