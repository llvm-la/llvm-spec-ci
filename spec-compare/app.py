from flask import Flask, render_template, request
from pathlib import Path
import json, math, statistics, os

app=Flask(__name__)
RESULT_DIR=Path(os.environ.get("SPEC_RESULT_DIR", Path(__file__).parent.parent/"spec-result"))
CONFIG_FILE=Path(__file__).parent/"config.json"
LINK_CFG=json.load(open(CONFIG_FILE,encoding="utf-8")) if CONFIG_FILE.exists() else {}

def load(path):
    with open(path,encoding="utf-8") as f: d=json.load(f)
    return {"file":Path(path).name,"data":d,"gerrit":d.get("gerrit",{}),"config":d.get("config",{}),"suites":d.get("suites",{})}

def discover():
    out=[]
    for p in sorted(RESULT_DIR.glob("*.json")):
        try:
            r=load(p); g=r["gerrit"]
            out.append({"file":r["file"],"change":g.get("change",""),"patchset":g.get("patchset",""),"build_number":g.get("build_number","")})
        except Exception as e: print("skip",p,e)
    return out

def avg(x): return statistics.mean(x) if x else None
FAILURE_CODES = {
    -1: "CE",    # Compilation Error
    -2: "RE",    # Runtime Error
    -3: "NOT_RUN",  # Did not appear in RSF
}
FAILURE_LABEL = {
    -1: "编译错误",
    -2: "运行时错误",
    -3: "未运行",
}
FAILURE_TIP = {
    -1: "Compilation Error: 编译失败，请检查编译日志",
    -2: "Runtime Error: 运行崩溃或非零退出码",
    -3: "Not Run: 基准测试已启用但未在 RSF 中出现",
}

def valid_score(x): return isinstance(x, list) and bool(x) and all(v>=0 for v in x)
def fail_code(x):
    """如果 ratio 单元素列表含负失败码，返回对应常量字符串，否则返回 None。"""
    if not isinstance(x, list) or len(x) != 1:
        return None
    v = x[0]
    if not isinstance(v, (int, float)) or v >= 0:
        return None
    return FAILURE_CODES.get(int(v))
def perf(old,new,higher):
    if old is None or new is None or old==0:return None
    return ((new-old) if higher else (old-new))/old*100
def geo(x):
    x=[v for v in x if v is not None and v>0]
    return math.exp(sum(math.log(v) for v in x)/len(x)) if x else None

def cfg(r,suite,bench):
    # Current result format: CPU2006 suites vs CPU2017 suites.
    name="cpu2006" if suite in ("cint","cfp") else "cpu2017"
    sc=r["config"].get(name,{})
    opt=dict(sc.get("compiler",{}).get("default",{}))
    opt.update({k:v for k,v in sc.get("benchmarks",{}).get(bench,{}).items() if k!="enabled"})
    return {"options":opt,"run":sc.get("run",{})}

def _normalize_ratio(r):
    """将 ratio 统一为 list：成功时已是 list，失败码(int)包装为 [code]。"""
    if isinstance(r, list):
        return r
    return [r]

def item(suite,bench,a,b):
    x=a["suites"].get(suite,{}).get(bench); y=b["suites"].get(suite,{}).get(bench)
    xt=x.get("time",[]) if x else []; yt=y.get("time",[]) if y else []
    xs=_normalize_ratio(x.get("ratio",[])) if x else []; ys=_normalize_ratio(y.get("ratio",[])) if y else []
    xsm=avg(xs) if valid_score(xs) else None; ysm=avg(ys) if valid_score(ys) else None
    fc_x=fail_code(xs); fc_y=fail_code(ys)
    return {"suite":suite,"benchmark":bench,"in_baseline":x is not None,"in_compare":y is not None,
      "baseline":{"time":xt,"ratio":xs,"time_mean":avg(xt),"score_mean":xsm,"score_valid":valid_score(xs),"fail_code":fc_x,"config":cfg(a,suite,bench) if x else None},
      "compare":{"time":yt,"ratio":ys,"time_mean":avg(yt),"score_mean":ysm,"score_valid":valid_score(ys),"fail_code":fc_y,"config":cfg(b,suite,bench) if y else None},
      "time_change":perf(avg(xt),avg(yt),False) if x and y else None,
      "score_change":perf(xsm,ysm,True) if xsm is not None and ysm is not None else None}

SUITE_YEAR = {
    "cint": "2006", "cfp": "2006",
    "intrate": "2017", "fprate": "2017", "intspeed": "2017", "fpspeed": "2017",
}

def _default_options(config, year_key):
    """Return {var: value} of default compiler options for a year group."""
    sc = config.get(year_key, {})
    return dict(sc.get("compiler", {}).get("default", {}))

def compare(a,b):
    # Group suites by SPEC year (2006 / 2017).
    years = {}
    for suite in sorted(set(a["suites"]) | set(b["suites"])):
        year = SUITE_YEAR.get(suite, "2017")
        years.setdefault(year, []).append(suite)

    out = []
    for year in sorted(years):
        suites = years[year]
        year_key = f"cpu{year}"
        # Default compiler options from baseline and compare separately.
        baseline_opts = _default_options(a["config"], year_key)
        compare_opts = _default_options(b["config"], year_key)
        baseline_run = (a["config"].get(year_key) or {}).get("run", {})
        compare_run = (b["config"].get(year_key) or {}).get("run", {})

        suite_list = []
        for suite in suites:
            aa=a["suites"].get(suite,{}); bb=b["suites"].get(suite,{})
            common=[]
            for bench in sorted(set(aa)|set(bb)):
                common.append(item(suite,bench,a,b))
            valid=[z for z in common if z["baseline"]["score_mean"] is not None and z["compare"]["score_mean"] is not None]
            # Geomean only when every benchmark in the suite ran successfully on both sides.
            if len(valid) == len(common) and common:
                ag=geo([z["baseline"]["score_mean"] for z in valid]); bg=geo([z["compare"]["score_mean"] for z in valid])
            else:
                ag=bg=None
            suite_list.append({"name":suite,"common":common,
              "baseline_geomean":ag,"compare_geomean":bg,"geomean_change":perf(ag,bg,True),"geomean_count":len(valid),"fail_count":len(common)-len(valid)})
        out.append({"year":year,"suites":suite_list,
          "baseline_options":baseline_opts,"compare_options":compare_opts,
          "baseline_run":baseline_run,"compare_run":compare_run})
    return out

@app.template_filter("number")
def number(v,digits=6): return "—" if v is None else f"{v:.{digits}f}"
@app.template_filter("percent")
def percent(v): return "—" if v is None else f"{v:+.2f}%"

@app.route("/")
def index():
    available=discover()
    if not available:return render_template("index.html",available=[],suites=None)
    bn=request.args.get("baseline",available[0]["file"])
    cn=request.args.get("compare",available[1]["file"] if len(available)>1 else available[0]["file"])
    try:
        a=load(RESULT_DIR/bn); b=load(RESULT_DIR/cn); suites=compare(a,b); err=None
    except Exception as e:
        a=b=None;suites=[];err=str(e)
    return render_template("index.html",available=available,baseline_name=bn,compare_name=cn,baseline=a,compare=b,suites=suites,error=err,link_cfg=LINK_CFG)

if __name__=="__main__":
    RESULT_DIR.mkdir(exist_ok=True)
    app.run(host="0.0.0.0",port=5005,debug=False)
