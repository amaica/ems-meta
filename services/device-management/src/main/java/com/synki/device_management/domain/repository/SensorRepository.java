package com.synki.device_management.domain.repository;

import com.synki.device_management.domain.model.Sensor;
import com.synki.device_management.domain.model.SensorId;
import org.springframework.data.jpa.repository.JpaRepository;

public interface SensorRepository extends JpaRepository<Sensor, SensorId> {
}
