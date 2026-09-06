pipeline {

    agent {
        label 'spec-perf'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    parameters {

        string(
            name: 'GERRIT_CHANGE',
            defaultValue: '',
            description: 'Gerrit Change Number，例如：12345'
        )

        string(
            name: 'GERRIT_PATCHSET',
            defaultValue: '',
            description: 'Gerrit Patchset Number，例如：1'
        )

        file(
            name: 'spec-ci.yaml',
            description: '上传 SPEC CI 配置文件'
        )

    }

    environment {
        CI_ROOT =
            '/path/to/ci'

        LLVM_SOURCE_DIR =
            '/path/to/llvm-project'

        LLVM_BUILD_DIR =
            '/path/to/build-llvm'

        # LLVM build defaults (overridable when calling build-llvm.sh).
        LLVM_BUILD_TYPE =
            'Release'

        LLVM_BUILD_JOBS =
            '32'

        LLVM_BUILD_MODE =
            'incremental'

        # Base commit that Gerrit patchsets are applied on top of.
        BASE_COMMIT =
            '0000000000000000000000000000000000000000'

        # SPEC installation directories (must contain shrc).
        SPEC_CPU2006_DIR =
            '/path/to/cpu2006'

        SPEC_CPU2017_DIR =
            '/path/to/cpu2017'

        # SPEC build directory: where generate.py writes .cfg/.sh files,
        # and where runspec/runcpu write results (also the --results-dir
        # passed to collect-result.py).
        SPEC_BUILD_DIR =
            '/path/to/build-spec'

        # SPEC result directory: where collect-result.py writes the
        # per-build result JSON (auto-named result-{author}-{change}-...).
        SPEC_RESULT_DIR =
            '/path/to/spec-result'

    }

 stages {

        stage('Validate Parameters') {

            steps {

                script {

                    if (
                        !params.GERRIT_CHANGE?.trim()
                    ) {

                        error(
                            'GERRIT_CHANGE is required'
                        )

                    }

                    if (
                        !params.GERRIT_PATCHSET?.trim()
                    ) {

                        error(
                            'GERRIT_PATCHSET is required'
                        )

                    }

                }

            }

        }


        stage('Cleanup') {

            steps {

                sh '''
                    set -eux

                    # Clean SPEC build dir: .cfg/.sh/.rsf are regenerated every run.
                    rm -rf "$SPEC_BUILD_DIR"
                    mkdir -p "$SPEC_BUILD_DIR"

                    # NOTE: $SPEC_RESULT_DIR is NOT cleaned — accumulated result
                    # JSON files are kept for cross-build comparison.
                    # NOTE: workspace (spec-ci.yaml etc.) is NOT cleaned here —
                    # it is still needed by Generate / Collect Result stages.
                '''

            }

        }


        stage('Verify Upload') {

            steps {

                script {

                    if (
                        !fileExists('spec-ci.yaml')
                    ) {

                        error(
                            'spec-ci.yaml is required — please upload it in the build parameters'
                        )

                    }

                }

            }

        }


        stage('Checkout Gerrit Patchset') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/checkout-patch.sh" \
                        "$GERRIT_CHANGE" \
                        "$GERRIT_PATCHSET"
                '''

            }

        }


        stage('Verify Source') {

            steps {

                sh '''
                    set -eux

                    cd "$LLVM_SOURCE_DIR"

                    echo "===== LLVM HEAD ====="

                    git log \
                        --oneline \
                        -5

                '''

            }

        }

        stage('Build LLVM') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/build-llvm.sh" \
                        "$LLVM_BUILD_TYPE" \
                        "$LLVM_BUILD_JOBS"  \
                        "$LLVM_BUILD_MODE"
                '''

            }

        }

        stage('Generate SPEC CFG + Run Scripts') {

            steps {

                sh '''
                    set -eux

                    python3 "$CI_ROOT/tools/generate.py" \
                        --yaml "$WORKSPACE/spec-ci.yaml" \
                        --llvm-dir "$LLVM_BUILD_DIR" \
                        --out "$SPEC_BUILD_DIR" \
                        --output-root "$SPEC_BUILD_DIR"
                '''

            }

        }

        stage('Run SPEC CPU2006') {

            steps {

                sh '''
                    set -eux

                    "$SPEC_BUILD_DIR/run-cpu2006.sh"
                '''

            }

        }

        stage('Run SPEC CPU2017') {

            steps {

                sh '''
                    set -eux

                    "$SPEC_BUILD_DIR/run-cpu2017.sh"
                '''

            }

        }

        stage('Collect Result') {

            steps {

                sh '''
                    set -eux

                    python3 "$CI_ROOT/tools/collect-result.py" \
                        --results-dir "$SPEC_BUILD_DIR" \
                        --spec-ci "$WORKSPACE/spec-ci.yaml" \
                        --output-dir "$SPEC_RESULT_DIR"
                '''

            }

        }

        stage('Package Results') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/package-build.sh" \
                        "$SPEC_BUILD_DIR" \
                        "$WORKSPACE"
                '''

                archiveArtifacts artifacts: 'spec-build-*.tar.gz', fingerprint: true
            }

        }

        stage('Cleanup Workspace') {

            steps {

                sh '''
                    set -eux

                    # Remove uploaded spec-ci.yaml and tarball — both are no
                    # longer needed after archiveArtifacts has captured them.
                    rm -f "$WORKSPACE/spec-ci.yaml"
                    rm -f "$WORKSPACE"/spec-build-*.tar.gz
                '''

            }

        }

    }

}
