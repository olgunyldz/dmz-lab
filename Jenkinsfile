// Uygulama deploy pipeline'ı (simülasyon). Hedef cluster ve namespace apps/<ad>/app.env kataloğundan gelir.
// Altyapı (cluster, ingress, Vault, platform) ayrı pipeline'dadır; bu pipeline onlara bağımlıdır.
// "all" sırası bağımlılıklara göre: auth-server (auth-server sırları) -> janus (janus-keys) -> fortuna (DB, seed) -> channel-gateway -> seal-intranet -> seal-mobile
pipeline {
    agent any
    parameters {
        choice(name: 'APP', choices: ['all', 'auth-server', 'janus', 'fortuna', 'channel-gateway', 'seal-intranet', 'seal-mobile'],
               description: 'Kurulacak uygulama (apps/<ad>/app.env) veya tümü (bağımlılık sırasıyla)')
        choice(name: 'REGISTRY_MODE', choices: ['kind', 'registry'],
               description: 'lab: kind (kind load); şirket: registry (build + push)')
    }
    environment {
        REGISTRY_MODE = "${params.REGISTRY_MODE}"
    }
    stages {
        stage('Doğrula') {
            steps {
                sh 'bash -n scripts/deploy-app.sh && bash -n scripts/lib/cluster.sh'
                sh 'if [ "$APP" != "all" ]; then test -f apps/$APP/app.env; fi'
            }
        }
        stage('Taban imajlar') {
            steps { sh "BASE_PUSH=${params.REGISTRY_MODE == 'registry' ? 1 : 0} bash images/build-base.sh" }
        }
        stage('Deploy') {
            steps {
                script {
                    def order = ['auth-server', 'janus', 'fortuna', 'channel-gateway', 'seal-intranet', 'seal-mobile']
                    def apps = params.APP == 'all' ? order : [params.APP]
                    apps.each { app -> sh "bash scripts/deploy-app.sh ${app}" }
                }
            }
        }
    }
    post {
        always { echo "Uygulama: ${params.APP}, sonuç: ${currentBuild.currentResult}" }
    }
}
