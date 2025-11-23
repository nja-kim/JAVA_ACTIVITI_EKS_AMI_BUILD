/* Licensed under the Apache License, Version 2.0 (the "License");
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */ //sudo vi src/main/java/supplychain/activiti/conf/ActivitiEngineConfiguration.java

package supplychain.activiti.conf;

import org.activiti.dmn.engine.DmnEngineConfiguration;
import org.activiti.dmn.engine.configurator.DmnEngineConfigurator;
import org.activiti.engine.*;
import org.activiti.engine.form.AbstractFormType;
import org.activiti.engine.impl.asyncexecutor.AsyncExecutor;
import org.activiti.engine.impl.asyncexecutor.DefaultAsyncJobExecutor;
import org.activiti.engine.impl.history.HistoryLevel;
import org.activiti.engine.parse.BpmnParseHandler;
import org.activiti.engine.runtime.Clock;
import org.activiti.spring.ProcessEngineFactoryBean;
import org.activiti.spring.SpringProcessEngineConfiguration;
import org.apache.commons.lang3.StringUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.DependsOn;
import org.springframework.core.env.Environment;
import org.springframework.transaction.PlatformTransactionManager;

import supplychain.entity.Location;
import supplychain.entity.VPort;
import supplychain.entity.WPort;
import supplychain.entity.Weagon;

import javax.inject.Inject;
import javax.persistence.EntityManagerFactory;
import javax.sql.DataSource;
import java.util.ArrayList;
import java.util.List;

@Configuration
@ComponentScan(
    basePackages = {
        "org.activiti.app.runtime.activiti",
        "org.activiti.app.extension.conf",
        "org.activiti.app.extension.bean",
        "supplychain.activiti.conf"
    },
    excludeFilters = @ComponentScan.Filter(
        type = org.springframework.context.annotation.FilterType.REGEX,
        pattern = "org\\.activiti\\.app\\.conf\\.ActivitiEngineConfiguration"
    )
)
public class ActivitiEngineConfiguration {

    private final Logger logger = LoggerFactory.getLogger(ActivitiEngineConfiguration.class);

    @Inject
    private DataSource dataSource;

    @Inject
    private PlatformTransactionManager transactionManager;

    @Inject
    private EntityManagerFactory entityManagerFactory;

    @Inject
    private Environment environment;

    // =========================================================================
    // CORE ENGINE CONFIGURATION
    // =========================================================================
    @Bean(name = "processEngine")
    public ProcessEngineFactoryBean processEngineFactoryBean() {
        ProcessEngineFactoryBean factoryBean = new ProcessEngineFactoryBean();
        factoryBean.setProcessEngineConfiguration(processEngineConfiguration());
        return factoryBean;
    }

    public ProcessEngine processEngine() {
        try {
            return processEngineFactoryBean().getObject();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    @Bean(name = "processEngineConfiguration")
    public SpringProcessEngineConfiguration processEngineConfiguration() {
        SpringProcessEngineConfiguration cfg = new SpringProcessEngineConfiguration();

        // -------------------- MAIN DATASOURCE CONFIG --------------------
        cfg.setDataSource(dataSource);
        cfg.setTransactionManager(transactionManager);
        cfg.setDatabaseType("mysql");
        cfg.setDatabaseSchemaUpdate(ProcessEngineConfiguration.DB_SCHEMA_UPDATE_FALSE);
        cfg.setHistory(HistoryLevel.AUDIT.getKey());
        cfg.setAsyncExecutorActivate(true);
        cfg.setAsyncExecutor(asyncExecutor());

        cfg.setJpaEntityManagerFactory(entityManagerFactory);
        cfg.setJpaCloseEntityManager(false);
        cfg.setJpaHandleTransaction(false);

        // Custom form types (domain models)
        List<AbstractFormType> customFormTypes = new ArrayList<>();
        customFormTypes.add(new Weagon());
        customFormTypes.add(new Location());
        customFormTypes.add(new VPort());
        customFormTypes.add(new WPort());
        cfg.setCustomFormTypes(customFormTypes);

        // Optional email configuration
        String emailHost = environment.getProperty("email.host");
        if (StringUtils.isNotEmpty(emailHost)) {
            cfg.setMailServerHost(emailHost);
            cfg.setMailServerPort(environment.getRequiredProperty("email.port", Integer.class));

            Boolean useCredentials = environment.getProperty("email.useCredentials", Boolean.class);
            if (Boolean.TRUE.equals(useCredentials)) {
                cfg.setMailServerUsername(environment.getProperty("email.username"));
                cfg.setMailServerPassword(environment.getProperty("email.password"));
            }

            Boolean emailSSL = environment.getProperty("email.ssl", Boolean.class);
            if (emailSSL != null) cfg.setMailServerUseSSL(emailSSL);

            Boolean emailTLS = environment.getProperty("email.tls", Boolean.class);
            if (emailTLS != null) cfg.setMailServerUseTLS(emailTLS);
        }

        // Cache limit
        cfg.setProcessDefinitionCacheLimit(
                environment.getProperty("activiti.process-definitions.cache.max", Integer.class, 128)
        );

        cfg.setEnableSafeBpmnXml(true);
        cfg.setPreBpmnParseHandlers(new ArrayList<BpmnParseHandler>());

        // =========================================================================
        // DISABLE FORM ENGINE (Prevents ACT_FO_* tables / Liquibase changelog)
        // =========================================================================
        try {
            logger.info("🧩 Disabling Activiti FormEngineConfigurator to prevent Liquibase schema creation...");
            System.setProperty("formEngineSchemaManagementEnabled", "false");
            // DO NOT add FormEngineConfigurator or FormEngineConfiguration
            // This keeps form API available but prevents Liquibase from running.
        } catch (Exception ex) {
            logger.error("Failed to disable form engine: {}", ex.getMessage(), ex);
        }

        // =========================================================================
        // DMN ENGINE CONFIGURATION (for decision tables)
        // =========================================================================
        try {
            DmnEngineConfiguration dmnCfg = new DmnEngineConfiguration();
            dmnCfg.setDataSource(dataSource);
            dmnCfg.setDatabaseSchemaUpdate(ProcessEngineConfiguration.DB_SCHEMA_UPDATE_FALSE);
            DmnEngineConfigurator dmnConf = new DmnEngineConfigurator();
            dmnConf.setDmnEngineConfiguration(dmnCfg);
            cfg.addConfigurator(dmnConf);
            logger.info("✅ DMN Engine configured successfully for MySQL 5.7.");
        } catch (Exception ex) {
            logger.error("Failed to configure DMN Engine: {}", ex.getMessage(), ex);
        }

        return cfg;
    }

    // =========================================================================
    // ASYNC EXECUTOR AND CORE SERVICES
    // =========================================================================
    @Bean
    public AsyncExecutor asyncExecutor() {
        DefaultAsyncJobExecutor asyncExecutor = new DefaultAsyncJobExecutor();
        asyncExecutor.setDefaultAsyncJobAcquireWaitTimeInMillis(5000);
        asyncExecutor.setDefaultTimerJobAcquireWaitTimeInMillis(5000);
        return asyncExecutor;
    }

    @Bean(name = "clock")
    @DependsOn("processEngine")
    public Clock getClock() {
        return processEngineConfiguration().getClock();
    }

    // =========================================================================
    // SERVICE BEANS
    // =========================================================================
    @Bean public RepositoryService repositoryService() { return processEngine().getRepositoryService(); }
    @Bean public RuntimeService runtimeService() { return processEngine().getRuntimeService(); }
    @Bean public TaskService taskService() { return processEngine().getTaskService(); }
    @Bean public HistoryService historyService() { return processEngine().getHistoryService(); }
    @Bean public IdentityService identityService() { return processEngine().getIdentityService(); }
    @Bean public ManagementService managementService() { return processEngine().getManagementService(); }

    // Form APIs remain accessible (stubs only; no schema)
    @Bean public FormService formService() { return processEngine().getFormService(); }
    @Bean public org.activiti.form.api.FormRepositoryService formEngineRepositoryService() {
        return processEngine().getFormEngineRepositoryService();
    }
    @Bean public org.activiti.form.api.FormService formEngineFormService() {
        return processEngine().getFormEngineFormService();
    }
}
