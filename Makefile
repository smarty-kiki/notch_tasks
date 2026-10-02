.PHONY: help build universal debug run package test preview icons clean

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## build      构建到 dist/NotchTasks.app（本机架构）
build:
	./build.sh

## universal  构建通用二进制（arm64 + x86_64）
universal:
	./build.sh --clean --universal

## debug      不优化、带调试符号
debug:
	./build.sh --clean --debug

## run        构建并启动
run:
	./run.sh

## package    打发布包 → dist/NotchTasks-<版本>-macos-<架构>.zip
package:
	./package.sh

## test       冒烟测试（不需要 GUI，也不需要本机数据）
test: build
	./scripts/smoke-test.sh

## preview    重新渲染 docs/preview 下的界面预览图
preview: build
	./build/NotchTasks --preview docs/preview

## icons      重新生成 App 图标（改完 tools/make-icon.swift 后跑）
icons:
	swift tools/make-icon.swift

## clean      清掉构建产物
clean:
	rm -rf build dist
