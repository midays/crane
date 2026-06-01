package e2e

import (
	"log"

	"github.com/konveyor/crane/e2e-tests/config"
	. "github.com/konveyor/crane/e2e-tests/framework"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Smoke test exercising the existing framework end-to-end with no OCP-specific
// machinery: deploy a stateless nginx via k8sdeploy on the source, run the
// crane export/transform/apply pipeline, apply the rendered manifests on the
// target, scale up the target deployment, and validate.
//
// Uses simple-nginx-nopv because it has no PVC/storage assumptions, which means
// no chmod dance, no transfer-pvc, no storage-class concerns — it's pure
// "can the framework move a stateless workload between two clusters."
//
// Skips the golden-manifest semantic diffs that mta_817 does — those require
// pre-recorded golden files for the specific cluster shape and are not what
// we're verifying here. We're verifying the *flow* works.
//
// Label "ocp" so it picks up on the OCP runner's default LABEL_FILTER='ocp';
// label "tier0" so it runs in the smoke band.
var _ = Describe("Crane framework smoke", func() {
	It("[CRANE-SMOKE] deploys app, runs crane pipeline, applies to target", Label("ocp", "tier0"), func() {
		appName := "simple-nginx-nopv"
		namespace := "simple-nginx-nopv"
		serviceName := "my-" + appName

		scenario := NewMigrationScenario(
			appName,
			namespace,
			config.K8sDeployBin,
			config.CraneBin,
			config.SourceContext,
			config.TargetContext,
		)
		srcApp := scenario.SrcApp
		tgtApp := scenario.TgtApp
		kubectlSrc := scenario.KubectlSrc
		kubectlTgt := scenario.KubectlTgt

		paths, err := NewScenarioPaths("crane-smoke-*")
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func() {
			By("Cleanup source and target resources")
			if err := CleanupScenario(paths.TempDir, srcApp, tgtApp); err != nil {
				log.Printf("cleanup: %v", err)
			}
		})

		By("Deploy and quiesce source app")
		log.Printf("Preparing source app %s in namespace %s", srcApp.Name, srcApp.Namespace)
		Expect(PrepareSourceApp(srcApp, kubectlSrc)).NotTo(HaveOccurred())

		By("Wait for source pods/endpoints to drain before export")
		WaitForSourceQuiesce(kubectlSrc, namespace, "app="+appName, serviceName)

		By("Run crane export/transform/apply pipeline")
		runner := scenario.Crane
		runner.WorkDir = paths.TempDir
		log.Printf("Running crane pipeline for namespace %s", srcApp.Namespace)
		Expect(RunCranePipelineWithChecks(runner, srcApp.Namespace, paths)).NotTo(HaveOccurred())

		By("Apply rendered manifests to target")
		log.Printf("Applying manifests from %s to target namespace %s", paths.OutputDir, namespace)
		Expect(ApplyOutputToTarget(kubectlTgt, namespace, paths.OutputDir)).NotTo(HaveOccurred())

		By("Scale target deployment and validate")
		log.Printf("Scaling target deployment(s) with label app=%s to 1", appName)
		Expect(kubectlTgt.ScaleDeployment(namespace, appName, 1)).NotTo(HaveOccurred())

		log.Printf("Validating app %s on target cluster", tgtApp.Name)
		Eventually(tgtApp.Validate, "2m", "10s").Should(Succeed())
		log.Printf("Smoke test completed successfully for %s", appName)
	})
})