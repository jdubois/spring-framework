/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Opt-in support for parallel bean instantiation during application context
 * bootstrap. Builds an approximate dependency graph of the singleton beans,
 * identifies independent chunks that can be created concurrently, and drives the
 * existing background-initialization machinery of the bean factory through a
 * bounded, CPU-sized thread pool.
 */
@NullMarked
package org.springframework.context.bootstrap.parallel;

import org.jspecify.annotations.NullMarked;
