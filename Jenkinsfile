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
            '/home/llvm-spec-ci/llvm-spec-perf'

        LLVM_SOURCE_DIR =
            '/home/llvm-spec-ci/llvm-spec-perf/repos/llvm-project'

        LLVM_BUILD_DIR =
            '/home/llvm-spec-ci/llvm-spec-perf/build-llvm'

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

        stage('Generate SPEC CFG') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/generate-spec-cfg.sh" \
                        "$WORKSPACE/spec-ci.yaml" \
                        "$LLVM_BUILD_DIR" \
                        "$WORKSPACE/spec-cfg"
                '''

            }

        }

        stage('Build SPEC') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/build-spec.sh" \
                        "$WORKSPACE/spec-ci.yaml" \
                        "$WORKSPACE/spec-cfg"
                '''

            }

        }

        stage('Run SPEC') {

            steps {

                sh '''
                    set -eux

                    "$CI_ROOT/scripts/run-spec.sh" \
                        "$WORKSPACE/spec-ci.yaml" \
                        "$WORKSPACE/spec-cfg"
                '''

            }

        }

        stage('Collect Result') {

            steps {

                sh '''
                    set -eux

                    python3 "$CI_ROOT/tools/collect-result.py" \
                        --results-dir "$WORKSPACE/spec-result" \
                        --spec-ci "$WORKSPACE/spec-ci.yaml" \
                        --output "$WORKSPACE/result.json"
                '''

            }

        }

    }

}
